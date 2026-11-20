import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { NotificationService } from '../src/lib/fcm.js';
import { createContext } from '../src/http/context.js';
import { createLogger } from '../src/lib/logger.js';
import {
  TEST_CONFIG,
  createDirect,
  createHarness,
  registerUser,
  truncateAll,
  type TestHarness,
  type TestUser,
} from './helpers.js';

let harness: TestHarness;
let gateway: ChatGateway;
let server: Server;
let port: number;

beforeAll(async () => {
  harness = await createHarness();
  const ctx = createContext(TEST_CONFIG, harness.db, harness.redis);
  const notifications = new NotificationService(TEST_CONFIG, createLogger(TEST_CONFIG, 'test'));
  gateway = new ChatGateway(TEST_CONFIG, ctx, notifications, createLogger(TEST_CONFIG, 'test'));
  await gateway.start();

  server = createServer();
  server.on('upgrade', (request, socket, head) => gateway.handleUpgrade(request, socket, head));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = (server.address() as { port: number }).port;
});

afterAll(async () => {
  await gateway.stop();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
});

type TestSocket = {
  send: (frame: unknown) => void;
  wait: (match: (frame: Record<string, unknown>) => boolean, timeoutMs?: number) => Promise<Record<string, unknown>>;
  close: () => void;
};

async function waitForRegistration(user: TestUser): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const node = await harness.redis.get(`conn:${user.id}:${user.deviceId}`);
    if (node) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('socket was never registered in Redis');
}

function connect(user: TestUser, { waitForRegistry = true } = {}): Promise<TestSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(user.accessToken)}`);
    const inbox: Record<string, unknown>[] = [];
    const waiters: {
      match: (frame: Record<string, unknown>) => boolean;
      resolve: (frame: Record<string, unknown>) => void;
      timer: NodeJS.Timeout;
    }[] = [];

    ws.on('message', (data) => {
      const frame = JSON.parse(data.toString()) as Record<string, unknown>;
      const index = waiters.findIndex((waiter) => waiter.match(frame));
      if (index >= 0) {
        const [waiter] = waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(frame);
      } else {
        inbox.push(frame);
      }
    });
    ws.on('error', reject);
    ws.on('open', () => {
      const socket: TestSocket = {
        send: (frame) => ws.send(JSON.stringify(frame)),
        wait: (match, timeoutMs = 4000) =>
          new Promise((res, rej) => {
            const existing = inbox.findIndex(match);
            if (existing >= 0) {
              res(inbox.splice(existing, 1)[0]!);
              return;
            }
            const timer = setTimeout(() => rej(new Error('timed out')), timeoutMs);
            waiters.push({ match, resolve: res, timer });
          }),
        close: () => ws.close(),
      };
      if (!waitForRegistry) {
        resolve(socket);
        return;
      }
      waitForRegistration(user).then(() => resolve(socket), reject);
    });
  });
}

async function pair() {
  const alice = await registerUser(harness, 'Alice');
  const bob = await registerUser(harness, 'Bob');
  const conversationId = await createDirect(harness, alice, bob);
  return { alice, bob, conversationId };
}

describe('chat gateway', () => {
  it('rejects an upgrade without a valid token', async () => {
    const outcome = await new Promise<string>((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=bogus`);
      ws.on('error', () => resolve('rejected'));
      ws.on('open', () => resolve('open'));
    });
    expect(outcome).toBe('rejected');
  });

  it('answers ping with pong', async () => {
    const { alice } = await pair();
    const socket = await connect(alice);

    socket.send({ type: 'ping' });
    const pong = await socket.wait((frame) => frame.type === 'pong');

    expect(pong.type).toBe('pong');
    socket.close();
  });

  it('acks the sender with `sent` and delivers to the recipient', async () => {
    const { alice, bob, conversationId } = await pair();
    const sender = await connect(alice);
    const recipient = await connect(bob);
    const clientMsgId = randomUUID();

    sender.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'Hello!',
    });

    const ack = await sender.wait((frame) => frame.type === 'status' && frame.status === 'sent');
    const delivered = await recipient.wait((frame) => frame.type === 'message');

    expect(ack).toMatchObject({ client_msg_id: clientMsgId, seq: 1, status: 'sent' });
    expect(delivered).toMatchObject({
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      seq: 1,
      sender_id: alice.id,
      msg_type: 'text',
      content: 'Hello!',
    });

    sender.close();
    recipient.close();
  });

  it('echoes the sender own message only as a status, not a message frame', async () => {
    const { alice, bob, conversationId } = await pair();
    const sender = await connect(alice);
    const recipient = await connect(bob);
    const clientMsgId = randomUUID();

    sender.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'echo',
    });
    await sender.wait((frame) => frame.type === 'status' && frame.status === 'sent');
    await recipient.wait((frame) => frame.type === 'message');

    await expect(sender.wait((frame) => frame.type === 'message', 400)).rejects.toThrow('timed out');

    sender.close();
    recipient.close();
  });

  it('propagates delivered and read status to the sender', async () => {
    const { alice, bob, conversationId } = await pair();
    const sender = await connect(alice);
    const recipient = await connect(bob);
    const clientMsgId = randomUUID();

    sender.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'status test',
    });
    await sender.wait((frame) => frame.type === 'status' && frame.status === 'sent');
    await recipient.wait((frame) => frame.type === 'message');

    recipient.send({ type: 'ack', conversation_id: conversationId, seq: 1, status: 'delivered' });
    const delivered = await sender.wait(
      (frame) => frame.type === 'status' && frame.status === 'delivered',
    );
    expect(delivered.client_msg_id).toBe(clientMsgId);

    recipient.send({ type: 'ack', conversation_id: conversationId, seq: 1, status: 'read' });
    const read = await sender.wait((frame) => frame.type === 'status' && frame.status === 'read');
    expect(read.client_msg_id).toBe(clientMsgId);

    const { rows } = await harness.db.query<{ last_read_seq: string }>(
      `SELECT last_read_seq FROM conversation_members
        WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, bob.id],
    );
    expect(Number(rows[0]!.last_read_seq)).toBe(1);

    sender.close();
    recipient.close();
  });

  it('rejects a send from a non-member', async () => {
    const { alice, bob, conversationId } = await pair();
    const eve = await registerUser(harness, 'Eve');
    const outsider = await connect(eve);
    const sender = await connect(alice);
    const recipient = await connect(bob);

    outsider.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'intruder',
    });
    const error = await outsider.wait((frame) => frame.type === 'error');
    expect(error.code).toBe('not_a_member');

    await expect(recipient.wait((frame) => frame.type === 'message', 400)).rejects.toThrow();

    outsider.close();
    sender.close();
    recipient.close();
  });

  it('rejects a non-UUIDv4 client_msg_id and empty text', async () => {
    const { alice, bob, conversationId } = await pair();
    const socket = await connect(alice);

    socket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: 'not-a-uuid',
      msg_type: 'text',
      content: 'x',
    });
    const badId = await socket.wait((frame) => frame.type === 'error');
    expect(badId.code).toBe('validation_error');

    socket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: '   ',
    });
    const empty = await socket.wait((frame) => frame.type === 'error');
    expect(empty.code).toBe('validation_error');

    socket.close();
    void bob;
  });

  it('deduplicates a retried send and keeps seq contiguous', async () => {
    const { alice, bob, conversationId } = await pair();
    const sender = await connect(alice);
    const recipient = await connect(bob);
    const clientMsgId = randomUUID();

    sender.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'once',
    });
    await sender.wait((frame) => frame.type === 'status' && frame.status === 'sent');
    await recipient.wait((frame) => frame.type === 'message');

    sender.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'once',
    });
    const retryAck = await sender.wait((frame) => frame.type === 'status' && frame.status === 'sent');
    expect(retryAck.seq).toBe(1);

    const secondId = randomUUID();
    sender.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: secondId,
      msg_type: 'text',
      content: 'second',
    });
    const secondAck = await sender.wait(
      (frame) => frame.type === 'status' && frame.client_msg_id === secondId,
    );
    expect(secondAck.seq).toBe(2);

    const { rows } = await harness.db.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM messages WHERE conversation_id = $1`,
      [conversationId],
    );
    expect(rows[0]!.count).toBe('2');

    sender.close();
    recipient.close();
  });

  it('registers and removes the connection routing map', async () => {
    const { alice } = await pair();
    const socket = await connect(alice);

    const node = await harness.redis.get(`conn:${alice.id}:${alice.deviceId}`);
    expect(node).toBe(TEST_CONFIG.gatewayNodeId);
    const presence = await harness.redis.get(`presence:${alice.id}`);
    expect(presence).not.toBeNull();

    socket.close();
    await new Promise((resolve) => setTimeout(resolve, 300));

    expect(await harness.redis.get(`conn:${alice.id}:${alice.deviceId}`)).toBeNull();
  });
});
