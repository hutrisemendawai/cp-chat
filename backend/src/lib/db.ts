import pg from 'pg';
import type { PoolClient, QueryResult, QueryResultRow } from 'pg';

export type { PoolClient, QueryResult, QueryResultRow };

export type Db = {
  query<R extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<QueryResult<R>>;
  connect(): Promise<PoolClient>;
  end(): Promise<void>;
};

export function createDb(databaseUrl: string): Db {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: 10 });

  pool.on('error', (error) => {
    console.error('Unexpected PostgreSQL pool error', error);
  });

  return {
    query: (text, values) => pool.query(text, values as unknown[] | undefined),
    connect: () => pool.connect(),
    end: () => pool.end(),
  };
}

export async function withTransaction<T>(
  db: Db,
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
