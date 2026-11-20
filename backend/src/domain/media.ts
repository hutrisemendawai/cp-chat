import type { Db } from '../lib/db.js';

export type MediaObjectRow = {
  id: string;
  owner_id: string;
  object_key: string;
  content_type: string;
  size_bytes: number;
  original_name: string | null;
  created_at: Date;
};

type RawMediaRow = Omit<MediaObjectRow, 'size_bytes'> & { size_bytes: string | number };

const COLUMNS = `id, owner_id, object_key, content_type, size_bytes, original_name, created_at`;

function mapMedia(row: RawMediaRow): MediaObjectRow {
  return { ...row, size_bytes: Number(row.size_bytes) };
}

export class MediaRepository {
  constructor(private readonly db: Db) {}

  async create(input: {
    ownerId: string;
    objectKey: string;
    contentType: string;
    sizeBytes: number;
    originalName: string | null;
  }): Promise<MediaObjectRow> {
    const { rows } = await this.db.query<RawMediaRow>(
      `INSERT INTO media_objects (owner_id, object_key, content_type, size_bytes, original_name)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING ${COLUMNS}`,
      [input.ownerId, input.objectKey, input.contentType, input.sizeBytes, input.originalName],
    );
    return mapMedia(rows[0]!);
  }

  async findByKey(objectKey: string): Promise<MediaObjectRow | null> {
    const { rows } = await this.db.query<RawMediaRow>(
      `SELECT ${COLUMNS} FROM media_objects WHERE object_key = $1`,
      [objectKey],
    );
    return rows[0] ? mapMedia(rows[0]) : null;
  }
}
