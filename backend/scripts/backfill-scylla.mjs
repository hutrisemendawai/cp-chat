#!/usr/bin/env node
/**
 * Backfills the wide-column message store from PostgreSQL.
 *
 * Phase 4 dual-writes new messages into ScyllaDB. Rows written before the
 * switch (or while the mirror was failing) still exist only in Postgres, so
 * this script replays them in `(conversation_id, seq)` order.
 *
 * Safe to re-run: Scylla writes are idempotent `INSERT`s keyed by
 * `(conversation_id, seq)` and `(sender_id, client_msg_id)`.
 *
 * Usage:
 *   MESSAGE_STORE=scylla node scripts/backfill-scylla.mjs [--batch 500] [--dry-run]
 */
import process from 'node:process';

import cassandra from 'cassandra-driver';
import pg from 'pg';

const args = new Map();
for (let index = 2; index < process.argv.length; index += 1) {
  const arg = process.argv[index];
  if (!arg.startsWith('--')) continue;
  const [key, inline] = arg.slice(2).split('=');
  args.set(key, inline ?? process.argv[++index] ?? true);
}

const batchSize = Number(args.get('batch') ?? 500);
const dryRun = args.has('dry-run');

const DATABASE_URL =
  process.env.DATABASE_URL ?? 'postgres://cpchat:cpchat@localhost:5432/cpchat?sslmode=disable';
const SCYLLA_CONTACT_POINTS = process.env.SCYLLA_CONTACT_POINTS ?? 'localhost:9042';
const SCYLLA_KEYSPACE = process.env.SCYLLA_KEYSPACE ?? 'cp_chat';
const SCYLLA_LOCAL_DATACENTER = process.env.SCYLLA_LOCAL_DATACENTER ?? 'datacenter1';

const pool = new pg.Pool({ connectionString: DATABASE_URL });
const scylla = new cassandra.Client({
  contactPoints: SCYLLA_CONTACT_POINTS.split(','),
  localDataCenter: SCYLLA_LOCAL_DATACENTER,
  keyspace: SCYLLA_KEYSPACE,
});

async function main() {
  await scylla.connect();

  const { rows: totals } = await pool.query('SELECT count(*)::bigint AS count FROM messages');
  const total = Number(totals[0].count);
  console.log(`${total} messages in PostgreSQL; batch=${batchSize}${dryRun ? ' (dry run)' : ''}`);

  let cursor = { conversationId: null, seq: 0 };
  let processed = 0;

  while (true) {
    const { rows } = await pool.query(
      `SELECT id, conversation_id, seq, sender_id, client_msg_id, type, content, created_at
         FROM messages
        WHERE ($1::uuid IS NULL)
           OR (conversation_id, seq) > ($1::uuid, $2::bigint)
        ORDER BY conversation_id, seq
        LIMIT $3`,
      [cursor.conversationId, cursor.seq, batchSize],
    );
    if (rows.length === 0) break;

    if (!dryRun) {
      // Unlogged batch per page keeps the two tables in step without paying a
      // per-row round trip. Rows are replayed idempotently on a re-run.
      const queries = rows.flatMap((row) => [
        {
          query: `INSERT INTO messages_by_conversation
                    (conversation_id, seq, message_id, sender_id, client_msg_id, type, content, created_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          params: [
            row.conversation_id,
            Number(row.seq),
            row.id,
            row.sender_id,
            row.client_msg_id,
            row.type,
            row.content,
            row.created_at,
          ],
        },
        {
          query: `INSERT INTO messages_by_client_id
                    (sender_id, client_msg_id, conversation_id, seq, message_id, type, content, created_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          params: [
            row.sender_id,
            row.client_msg_id,
            row.conversation_id,
            Number(row.seq),
            row.id,
            row.type,
            row.content,
            row.created_at,
          ],
        },
      ]);

      await scylla.batch(queries, { prepare: true });
    }

    processed += rows.length;
    const last = rows[rows.length - 1];
    cursor = { conversationId: last.conversation_id, seq: Number(last.seq) };
    process.stdout.write(`\r${processed}/${total} messages mirrored`);
  }

  console.log(`\nDone. ${processed} messages ${dryRun ? 'scanned' : 'written to ScyllaDB'}.`);
}

main()
  .catch((error) => {
    console.error('backfill failed:', error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await scylla.shutdown().catch(() => undefined);
    await pool.end();
  });
