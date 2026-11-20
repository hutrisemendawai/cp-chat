/**
 * Live end-to-end smoke test for the realtime stack.
 *
 * Prereqs: PostgreSQL, Redis, the REST server and the gateway are running.
 * Usage: `node scripts/smoke.mjs [restBase] [wsBase]`
 */
import { randomUUID } from 'node:crypto';

const REST = process.argv[2] ?? process.env.REST_BASE_URL ?? 'http://localhost:8088';
const WS = process.argv[3] ?? process.env.WS_BASE_URL ?? 'ws://localhost:8081';

const stamp = Date.now();
const results = [];

function check(name, ok, detail = '') {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}

async function rest(path, { method = 'GET', body, token } = {}) {
  const response = await fetch(`${REST}${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  return { status: response.status, json };
}

function openSocket(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS}/ws?token=${encodeURIComponent(token)}`);
    const inbox = [];
    const waiters = [];

    ws.addEventListener('message', (event) => {
      const frame = JSON.parse(event.data);
      const index = waiters.findIndex((waiter) => waiter.match(frame));
      if (index >= 0) {
        const [waiter] = waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(frame);
      } else {
        inbox.push(frame);
      }
    });
    ws.addEventListener('error', () => reject(new Error('socket error')));
    ws.addEventListener('open', () =>
      resolve({
        ws,
        send: (frame) => ws.send(JSON.stringify(frame)),
        wait: (match, timeoutMs = 4000) =>
          new Promise((res, rej) => {
            const existing = inbox.findIndex(match);
            if (existing >= 0) {
              res(inbox.splice(existing, 1)[0]);
              return;
            }
            const timer = setTimeout(() => rej(new Error('timed out waiting for frame')), timeoutMs);
            waiters.push({ match, resolve: res, timer });
          }),
        close: () => ws.close(),
      }),
    );
  });
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const aliceEmail = `alice+${stamp}@example.com`;
  const bobEmail = `bob+${stamp}@example.com`;

  const alice = await rest('/api/v1/auth/register', {
    method: 'POST',
    body: { phone_or_email: aliceEmail, name: 'Alice', password: 'password123' },
  });
  const bob = await rest('/api/v1/auth/register', {
    method: 'POST',
    body: { phone_or_email: bobEmail, name: 'Bob', password: 'password123' },
  });
  check('register two users', alice.status === 201 && bob.status === 201);

  const aliceToken = alice.json.access_token;
  const bobToken = bob.json.access_token;

  const conversation = await rest('/api/v1/conversations', {
    method: 'POST',
    token: aliceToken,
    body: { type: 'direct', member_ids: [bob.json.user.id] },
  });
  const conversationId = conversation.json.id;
  check('create direct conversation', conversation.status === 201, conversationId);

  const aliceSocket = await openSocket(aliceToken);
  const bobSocket = await openSocket(bobToken);
  check('both sockets connect', true);

  const rejected = await new Promise((resolve) => {
    const ws = new WebSocket(`${WS}/ws?token=not-a-token`);
    ws.addEventListener('error', () => resolve(true));
    ws.addEventListener('open', () => resolve(false));
  });
  check('invalid token rejected on upgrade', rejected);

  const clientMsgId = randomUUID();
  const sentAt = Date.now();
  aliceSocket.send({
    type: 'send',
    conversation_id: conversationId,
    client_msg_id: clientMsgId,
    msg_type: 'text',
    content: 'Hello Bob!',
  });

  const ack = await aliceSocket.wait(
    (frame) => frame.type === 'status' && frame.client_msg_id === clientMsgId && frame.status === 'sent',
  );
  const latency = Date.now() - sentAt;
  check('sender receives sent ACK with seq', ack.seq === 1, `seq=${ack.seq}, ${latency}ms`);

  const delivered = await bobSocket.wait(
    (frame) => frame.type === 'message' && frame.client_msg_id === clientMsgId,
  );
  check(
    'recipient receives message frame',
    delivered.conversation_id === conversationId && delivered.seq === 1,
  );

  bobSocket.send({ type: 'ack', conversation_id: conversationId, seq: 1, status: 'delivered' });
  const deliveredStatus = await aliceSocket.wait(
    (frame) => frame.type === 'status' && frame.client_msg_id === clientMsgId && frame.status === 'delivered',
  );
  check('sender learns delivery', deliveredStatus.seq === 1);

  bobSocket.send({ type: 'ack', conversation_id: conversationId, seq: 1, status: 'read' });
  const readStatus = await aliceSocket.wait(
    (frame) => frame.type === 'status' && frame.client_msg_id === clientMsgId && frame.status === 'read',
  );
  check('sender learns read', readStatus.seq === 1);

  // Idempotent retry: same client_msg_id must not create a second message.
  aliceSocket.send({
    type: 'send',
    conversation_id: conversationId,
    client_msg_id: clientMsgId,
    msg_type: 'text',
    content: 'Hello Bob!',
  });
  const retryAck = await aliceSocket.wait(
    (frame) => frame.type === 'status' && frame.client_msg_id === clientMsgId,
  );
  check('retry re-uses the original seq', retryAck.seq === 1);

  const bobAfterRetry = await rest(`/api/v1/conversations/${conversationId}/messages`, {
    token: bobToken,
  });
  check('duplicate send stored once', bobAfterRetry.json.messages.length === 1);

  // Ordering under a burst.
  const burst = Array.from({ length: 5 }, (_, index) => ({
    clientMsgId: randomUUID(),
    content: `burst ${index}`,
  }));
  for (const message of burst) {
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: message.clientMsgId,
      msg_type: 'text',
      content: message.content,
    });
  }
  const burstSeqs = new Set();
  for (let index = 0; index < burst.length; index += 1) {
    const frame = await aliceSocket.wait(
      (candidate) =>
        candidate.type === 'status' &&
        candidate.status === 'sent' &&
        burst.some((message) => message.clientMsgId === candidate.client_msg_id),
    );
    burstSeqs.add(frame.seq);
  }
  const sorted = [...burstSeqs].sort((a, b) => a - b);
  const contiguous = sorted.every((seq, index) => seq === sorted[0] + index);
  check(
    'burst assigns unique contiguous seq with no holes',
    sorted.length === 5 && contiguous && sorted[0] === 2,
    sorted.join(','),
  );

  // Offline recipient: sync recovers everything after the local cursor.
  bobSocket.close();
  await sleep(250);
  const cursorBeforeOffline = Math.max(...sorted);
  const offlineMsgId = randomUUID();
  aliceSocket.send({
    type: 'send',
    conversation_id: conversationId,
    client_msg_id: offlineMsgId,
    msg_type: 'text',
    content: 'While you were away',
  });
  const offlineAck = await aliceSocket.wait(
    (frame) => frame.type === 'status' && frame.client_msg_id === offlineMsgId,
  );
  check(
    'message accepted while recipient offline',
    offlineAck.seq === cursorBeforeOffline + 1,
    `seq=${offlineAck.seq}`,
  );

  const sync = await rest(`/api/v1/conversations/${conversationId}/sync?after_seq=1`, {
    token: bobToken,
  });
  const expectedMissed = offlineAck.seq - 1;
  check(
    'sync returns missed messages ascending',
    sync.json.messages.length === expectedMissed &&
      sync.json.messages[0].seq === 2 &&
      sync.json.latest_seq === offlineAck.seq,
    `${sync.json.messages.length} messages, latest_seq=${sync.json.latest_seq}`,
  );

  // Unread counts come from last_read_seq, not from receipts. Bob read seq 1.
  const list = await rest('/api/v1/conversations', { token: bobToken });
  const entry = list.json.conversations.find((item) => item.id === conversationId);
  check(
    'unread count reflects missed messages',
    entry?.unread_count === expectedMissed,
    `unread=${entry?.unread_count}`,
  );

  const history = await rest(
    `/api/v1/conversations/${conversationId}/messages?before_seq=5&limit=2`,
    { token: bobToken },
  );
  check(
    'history pagination is seq-descending and exclusive',
    history.json.messages.map((message) => message.seq).join(',') === '4,3' && history.json.has_more,
  );

  const outsider = await rest(`/api/v1/conversations/${conversationId}/messages`, {
    token: (await rest('/api/v1/auth/register', {
      method: 'POST',
      body: { phone_or_email: `eve+${stamp}@example.com`, name: 'Eve', password: 'password123' },
    })).json.access_token,
  });
  check('non-member cannot read history', outsider.status === 403, `status=${outsider.status}`);

  aliceSocket.close();

  const failures = results.filter((result) => !result.ok);
  console.log(`\n${results.length - failures.length}/${results.length} checks passed`);
  if (failures.length > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error('smoke test crashed:', error);
  process.exitCode = 1;
});
