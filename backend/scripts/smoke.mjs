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

  // Phase 2: group fan-out and aggregated read receipt.
  const carol = await rest('/api/v1/auth/register', {
    method: 'POST',
    body: { phone_or_email: `carol+${stamp}@example.com`, name: 'Carol', password: 'password123' },
  });
  const carolToken = carol.json.access_token;

  const group = await rest('/api/v1/conversations', {
    method: 'POST',
    token: aliceToken,
    body: {
      type: 'group',
      name: 'Smoke Group',
      member_ids: [bob.json.user.id, carol.json.user.id],
    },
  });
  check('create group', group.status === 201, group.json?.id);
  const groupId = group.json.id;
  check(
    'creator is the only admin',
    group.json.members.filter((member) => member.role === 'admin').length === 1,
  );

  const carolSocket = await openSocket(carolToken);
  const groupMsgId = randomUUID();
  aliceSocket.send({
    type: 'send',
    conversation_id: groupId,
    client_msg_id: groupMsgId,
    msg_type: 'text',
    content: 'Hello group!',
  });
  const groupAck = await aliceSocket.wait(
    (frame) => frame.type === 'status' && frame.client_msg_id === groupMsgId && frame.status === 'sent',
  );
  check('group message accepted', groupAck.seq === 1, `seq=${groupAck.seq}`);

  const groupDelivery = await carolSocket.wait(
    (frame) => frame.type === 'message' && frame.client_msg_id === groupMsgId,
  );
  check('group message fans out to every member', groupDelivery.seq === 1);

  carolSocket.send({ type: 'ack', conversation_id: groupId, seq: 1, status: 'read' });
  const receipt = await aliceSocket.wait((frame) => frame.type === 'read_receipt');
  check(
    'aggregated read receipt reaches the sender',
    receipt.read_count === 1 && receipt.member_count === 2,
    `read=${receipt.read_count}/${receipt.member_count}`,
  );

  const added = await rest(`/api/v1/conversations/${groupId}/members`, {
    method: 'POST',
    token: aliceToken,
    body: { user_ids: [bob.json.user.id] },
  });
  check(
    'admin can add members (idempotent)',
    added.status === 200 &&
      added.json.some((member) => member.user.id === bob.json.user.id),
  );

  // Phase 2: media presign + private resolution.
  const presigned = await rest('/api/v1/media/presign', {
    method: 'POST',
    token: aliceToken,
    body: { filename: 'smoke.png', content_type: 'image/png', size_bytes: 1024 },
  });
  check(
    'media presign returns an upload URL',
    presigned.status === 201 && typeof presigned.json.upload_url === 'string',
  );
  const tooLarge = await rest('/api/v1/media/presign', {
    method: 'POST',
    token: aliceToken,
    body: { filename: 'huge.mp4', content_type: 'video/mp4', size_bytes: 999_999_999 },
  });
  check('media size limit is enforced', tooLarge.status === 413, `status=${tooLarge.status}`);

  // Phase 3: message search, presence, multi-device routing.
  const chatSearch = await rest(
    `/api/v1/conversations/${conversationId}/search?q=${encodeURIComponent('Hello')}`,
    { token: bobToken },
  );
  check(
    'in-chat search finds a message',
    chatSearch.status === 200 && chatSearch.json.messages.some((m) => m.content === 'Hello Bob!'),
    `${chatSearch.json.messages.length} hits`,
  );

  const globalSearch = await rest(`/api/v1/search?q=${encodeURIComponent('burst')}`, {
    token: bobToken,
  });
  check(
    'global search only returns the caller messages',
    globalSearch.status === 200 && globalSearch.json.messages.length >= 1,
    `${globalSearch.json.messages.length} hits`,
  );

  const outsiderSearch = await rest(`/api/v1/search?q=${encodeURIComponent('burst')}`, {
    token: (await rest('/api/v1/auth/register', {
      method: 'POST',
      body: { phone_or_email: `frank+${stamp}@example.com`, name: 'Frank', password: 'password123' },
    })).json.access_token,
  });
  check(
    'global search is scoped to the caller memberships',
    outsiderSearch.json.messages.length === 0,
  );

  const presence = await rest(`/api/v1/presence/${alice.json.user.id}`, { token: bobToken });
  check(
    'presence endpoint reports online while the socket is open',
    presence.status === 200 && presence.json.online === true,
  );

  // A second login of Bob on another device would receive a mirrored frame when
  // Bob sends from elsewhere; the gateway tests cover that path directly.

  carolSocket.close();
  aliceSocket.close();

  const offline = await new Promise((resolve) => setTimeout(resolve, 300)).then(() =>
    rest(`/api/v1/presence/${alice.json.user.id}`, { token: bobToken }),
  );
  check(
    'presence reports offline with a last-seen timestamp after disconnect',
    offline.json.online === false && typeof offline.json.last_seen_at === 'string',
  );

  // Phase 4: E2EE key registry. Publish a bundle, fetch it as a peer, and
  // confirm the one-time prekey is consumed exactly once.
  const fakeKey = (label) => Buffer.from(label.padEnd(32, '.')).toString('base64');
  const published = await rest('/api/v1/keys', {
    method: 'POST',
    token: bobToken,
    body: {
      identity_key: fakeKey('identity'),
      signing_key: fakeKey('signing'),
      signed_prekey: { key_id: 1, public_key: fakeKey('signed'), signature: fakeKey('sig') },
      one_time_prekeys: [
        { key_id: 10, public_key: fakeKey('otp-10') },
        { key_id: 11, public_key: fakeKey('otp-11') },
      ],
    },
  });
  check(
    'publishes E2EE keys',
    published.status === 201 && published.json.one_time_prekeys === 2,
    `stored=${published.json?.one_time_prekeys}`,
  );

  const bundle = await rest(`/api/v1/keys/${bob.json.user.id}`, { token: aliceToken });
  check(
    'fetches a prekey bundle and consumes one one-time prekey',
    bundle.status === 200 &&
      bundle.json.one_time_prekey?.key_id === 10 &&
      bundle.json.remaining_one_time_prekeys === 1,
    `spk=${bundle.json?.signed_prekey?.key_id}, otp=${bundle.json?.one_time_prekey?.key_id}`,
  );

  const secondBundle = await rest(`/api/v1/keys/${bob.json.user.id}`, { token: carolToken });
  check(
    'a second fetch never receives the same one-time prekey',
    secondBundle.json.one_time_prekey?.key_id === 11,
  );

  // An E2EE envelope is relayed verbatim; a malformed one is rejected.
  // Reconnect: the sockets above were closed to exercise the offline-presence
  // path, and the envelope checks need a live sender.
  const envelopeSocket = await openSocket(aliceToken);
  const envelope = `e2ee:v1:${JSON.stringify({
    v: 1,
    ik: fakeKey('identity'),
    ek: fakeKey('ephemeral'),
    spk: 1,
    i: 0,
    ct: 'Y2lwaGVydGV4dA==',
    n: 'MDEyMzQ1Njc4OWFi',
    m: 'MDEyMzQ1Njc4OWFiY2RlZg==',
  })}`;
  envelopeSocket.send({
    type: 'send',
    conversation_id: conversationId,
    client_msg_id: randomUUID(),
    msg_type: 'text',
    content: envelope,
  });
  const encryptedAck = await envelopeSocket.wait(
    (frame) => frame.type === 'status' && frame.status === 'sent' && frame.seq > offlineAck.seq,
  );
  const stored = await rest(`/api/v1/conversations/${conversationId}/messages`, {
    token: bobToken,
  });
  check(
    'relays an E2EE envelope as opaque content',
    stored.json.messages.some((message) => message.content === envelope),
    `seq=${encryptedAck.seq}`,
  );

  envelopeSocket.send({
    type: 'send',
    conversation_id: conversationId,
    client_msg_id: randomUUID(),
    msg_type: 'text',
    content: 'e2ee:v1:not-json',
  });
  const rejectedEnvelope = await envelopeSocket.wait(
    (frame) => frame.type === 'error' && frame.code === 'validation_error',
  );
  check('rejects a malformed E2EE envelope', rejectedEnvelope.code === 'validation_error');
  envelopeSocket.close();

  const failures = results.filter((result) => !result.ok);
  console.log(`\n${results.length - failures.length}/${results.length} checks passed`);
  if (failures.length > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error('smoke test crashed:', error);
  process.exitCode = 1;
});
