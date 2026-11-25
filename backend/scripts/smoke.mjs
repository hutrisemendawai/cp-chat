/**
 * Live end-to-end smoke test for the realtime stack.
 *
 * Prereqs: PostgreSQL, Redis, the REST server and the gateway are running.
 * Usage: `node scripts/smoke.mjs [restBase] [wsBase]`
 */
import { randomUUID } from 'node:crypto';

const REST = process.argv[2] ?? process.env.REST_BASE_URL ?? 'http://localhost:8080';
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
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
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

/** Raw-body variant: uploads binary bytes and returns them back unparsed. */
async function upload(path, { bytes, contentType, filename, token } = {}) {
  const response = await fetch(`${REST}${path}`, {
    method: 'POST',
    headers: {
      'content-type': contentType,
      ...(filename ? { 'x-filename': filename } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: bytes,
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

/** Fetches a media object and returns the raw bytes plus headers. */
async function download(path, { token, queryToken } = {}) {
  const url = queryToken
    ? `${REST}${path}${path.includes('?') ? '&' : '?'}token=${encodeURIComponent(queryToken)}`
    : `${REST}${path}`;
  const response = await fetch(url, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
  const buffer = Buffer.from(await response.arrayBuffer());
  return { status: response.status, buffer, headers: response.headers };
}

/**
 * Optional shared secret for `/logs` and `/api/v1/logs*`. When the deployment
 * sets `LOG_VIEWER_TOKEN`, the viewer is closed and this is required.
 */
const LOG_TOKEN = process.env.LOG_VIEWER_TOKEN ?? '';
const withLogToken = (path) =>
  LOG_TOKEN ? `${path}${path.includes('?') ? '&' : '?'}token=${encodeURIComponent(LOG_TOKEN)}` : path;

/** Fetches a non-JSON endpoint (the HTML log dashboard). */
async function fetchText(path) {
  const response = await fetch(`${REST}${path}`);
  return { status: response.status, text: await response.text() };
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
    body: {
      phone_or_email: aliceEmail,
      username: `alice_${stamp}`,
      name: 'Alice',
      password: 'password123',
    },
  });
  const bob = await rest('/api/v1/auth/register', {
    method: 'POST',
    body: {
      phone_or_email: bobEmail,
      username: `bob_${stamp}`,
      name: 'Bob',
      password: 'password123',
    },
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
      body: { phone_or_email: `eve+${stamp}@example.com`, username: `eve_${stamp}`, name: 'Eve', password: 'password123' },
    })).json.access_token,
  });
  check('non-member cannot read history', outsider.status === 403, `status=${outsider.status}`);

  // Phase 2: group fan-out and aggregated read receipt.
  const carol = await rest('/api/v1/auth/register', {
    method: 'POST',
    body: {
      phone_or_email: `carol+${stamp}@example.com`,
      username: `carol_${stamp}`,
      name: 'Carol',
      password: 'password123',
    },
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
      body: { phone_or_email: `frank+${stamp}@example.com`, username: `frank_${stamp}`, name: 'Frank', password: 'password123' },
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

  // ---- Phase 6: profiles, friends, proxied media, and the log timeline ----
  const dave = await rest('/api/v1/auth/register', {
    method: 'POST',
    body: {
      phone_or_email: `dave+${stamp}@example.com`,
      username: `dave_${stamp}`,
      name: 'Dave Smoke',
      password: 'password123',
    },
  });
  const daveToken = dave.json.access_token;
  const daveId = dave.json.user.id;

  // Profile: nickname, bio, and each Discord-style presence preference.
  const profile = await rest('/api/v1/users/me', {
    method: 'PATCH',
    token: daveToken,
    body: { nickname: 'dave', bio: 'Smoke-testing the profile.', custom_status: 'verifying' },
  });
  check(
    'profile update stores nickname, bio and custom status',
    profile.status === 200 &&
      profile.json.nickname === 'dave' &&
      profile.json.bio === 'Smoke-testing the profile.' &&
      profile.json.custom_status === 'verifying',
    `nickname=${profile.json?.nickname}`,
  );

  const statusResults = [];
  for (const wanted of ['idle', 'dnd', 'invisible']) {
    const response = await rest('/api/v1/users/me', {
      method: 'PATCH',
      token: daveToken,
      body: { status: wanted },
    });
    statusResults.push({ wanted, ok: response.status === 200 && response.json.status === wanted });
    if (wanted === 'invisible') {
      // `invisible` must never leak to a peer: the effective view is offline.
      const asPeer = await rest(`/api/v1/users/${daveId}`, { token: aliceToken });
      check(
        'invisible status is masked as offline for peers',
        asPeer.json.effective_status === 'offline' && asPeer.json.online === false,
        `effective=${asPeer.json?.effective_status}`,
      );
    }
  }
  check(
    'status accepts idle, dnd and invisible',
    statusResults.every((result) => result.ok),
    statusResults.filter((r) => !r.ok).map((r) => r.wanted).join(',') || 'idle,dnd,invisible',
  );

  // Directory live search over username and email, excluding the caller and
  // never returning an email address.
  const byUsername = await rest(`/api/v1/users/search?q=${encodeURIComponent(`dave_${stamp}`)}`, {
    token: aliceToken,
  });
  const byEmail = await rest(`/api/v1/users/search?q=${encodeURIComponent('dave+')}`, {
    token: aliceToken,
  });
  check(
    'user search finds a user by username',
    byUsername.status === 200 && byUsername.json.users.some((user) => user.id === daveId),
    `${byUsername.json.users?.length ?? 0} hits`,
  );
  check(
    'user search finds a user by email',
    byEmail.status === 200 && byEmail.json.users.some((user) => user.id === daveId),
    `${byEmail.json.users?.length ?? 0} hits`,
  );
  check(
    'user search omits the email and paginates',
    byUsername.json.users.every((user) => user.email === undefined && user.phone_or_email === undefined) &&
      byUsername.json.limit === 10 &&
      byUsername.json.has_more === false,
    `limit=${byUsername.json?.limit}, has_more=${byUsername.json?.has_more}`,
  );
  const tooShort = await rest(`/api/v1/users/search?q=${encodeURIComponent('ab')}`, {
    token: aliceToken,
  });
  check('user search enforces a 3-character minimum', tooShort.status === 422, `status=${tooShort.status}`);
  const selfSearch = await rest(
    `/api/v1/users/search?q=${encodeURIComponent(`alice_${stamp}`)}`,
    { token: aliceToken },
  );
  check(
    'user search never returns the caller',
    selfSearch.json.users.every((user) => user.id !== alice.json.user.id),
  );

  // Friends: add by identifier, list, then remove.
  const addedFriend = await rest('/api/v1/friends', {
    method: 'POST',
    token: aliceToken,
    body: { identifier: `dave+${stamp}@example.com` },
  });
  check(
    'adds a friend by email',
    addedFriend.status === 201 && addedFriend.json.id === daveId,
    `status=${addedFriend.status}`,
  );
  const friendList = await rest('/api/v1/friends', { token: aliceToken });
  check(
    'lists the friend with a profile projection',
    friendList.status === 200 &&
      friendList.json.friends.some(
        (friend) => friend.id === daveId && friend.nickname === 'dave' && friend.is_friend === true,
      ),
    `${friendList.json.friends?.length ?? 0} friends`,
  );
  const removedFriend = await rest(`/api/v1/friends/${daveId}`, {
    method: 'DELETE',
    token: aliceToken,
  });
  const afterRemoval = await rest('/api/v1/friends', { token: aliceToken });
  check(
    'removes the friend',
    removedFriend.status === 204 &&
      !afterRemoval.json.friends.some((friend) => friend.id === daveId),
    `status=${removedFriend.status}`,
  );

  // Proxied media: upload bytes through the API, read them back, and confirm a
  // stranger is refused while a profile avatar is readable app-wide.
  const pngBytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01]);
  const uploaded = await upload('/api/v1/media/upload', {
    bytes: pngBytes,
    contentType: 'image/png',
    filename: 'avatar.png',
    token: daveToken,
  });
  const mediaKey = uploaded.json?.object_key;
  check(
    'proxied upload stores media and returns a key',
    uploaded.status === 201 &&
      typeof mediaKey === 'string' &&
      uploaded.json.content_type === 'image/png' &&
      uploaded.json.size_bytes === pngBytes.length,
    `status=${uploaded.status}`,
  );

  const streamed = await download(`/api/v1/media/${mediaKey}`, { token: daveToken });
  check(
    'streams the uploaded bytes back without a redirect',
    streamed.status === 200 &&
      streamed.buffer.equals(pngBytes) &&
      streamed.headers.get('location') === null &&
      streamed.headers.get('content-type') === 'image/png' &&
      streamed.headers.get('cache-control') === 'private, max-age=300',
    `status=${streamed.status}, ${streamed.buffer.length}B`,
  );

  const strangerMedia = await download(`/api/v1/media/${mediaKey}`, { token: bobToken });
  check(
    'a stranger cannot read a non-avatar object',
    strangerMedia.status === 403,
    `status=${strangerMedia.status}`,
  );

  const setAvatar = await rest('/api/v1/users/me', {
    method: 'PATCH',
    token: daveToken,
    body: { avatar_url: mediaKey },
  });
  // Carol shares no conversation or friendship with Dave, so this isolates the
  // avatar rule rather than the conversation-partner rule.
  const avatarAsStranger = await download(`/api/v1/media/${mediaKey}`, { token: carolToken });
  check(
    'a non-contact can read a profile avatar',
    setAvatar.status === 200 && avatarAsStranger.status === 200,
    `status=${avatarAsStranger.status}`,
  );

  const queryTokenMedia = await download(`/api/v1/media/${mediaKey}`, {
    queryToken: carolToken,
  });
  check(
    'media download accepts a query token for image widgets',
    queryTokenMedia.status === 200 && queryTokenMedia.buffer.equals(pngBytes),
    `status=${queryTokenMedia.status}`,
  );

  // Logs: a mobile diagnostic lands in the shared buffer and is queryable.
  const logTag = `smoke-${stamp}`;
  const pushedLog = await rest('/api/v1/logs/client', {
    method: 'POST',
    token: daveToken,
    body: { level: 'warn', tag: 'smoke', message: `phase6 ${logTag}`, meta: { run: logTag } },
  });
  check('accepts a mobile diagnostic log entry', pushedLog.status === 202, `status=${pushedLog.status}`);

  const logQuery = await rest(withLogToken(`/api/v1/logs?q=${encodeURIComponent(logTag)}&limit=50`));
  check(
    'log API returns the ingested entry',
    logQuery.status === 200 &&
      Array.isArray(logQuery.json.logs) &&
      logQuery.json.logs.some((entry) => entry.message === `phase6 ${logTag}`),
    `${logQuery.json.logs?.length ?? 0} entries`,
  );
  check(
    'log API reports the one-hour retention window',
    logQuery.json.retention_seconds === 3600,
    `retention=${logQuery.json.retention_seconds}s`,
  );

  const dashboard = await fetchText(withLogToken('/logs'));
  check(
    'live log dashboard renders over HTTP',
    dashboard.status === 200 &&
      dashboard.text.includes('CP Chat — Live Logs') &&
      dashboard.text.includes('/api/v1/logs/stream'),
    `status=${dashboard.status}`,
  );

  const failures = results.filter((result) => !result.ok);
  console.log(`\n${results.length - failures.length}/${results.length} checks passed`);
  if (failures.length > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error('smoke test crashed:', error);
  process.exitCode = 1;
});
