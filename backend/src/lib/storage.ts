import { randomUUID } from 'node:crypto';

import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

import type { Config } from '../config.js';

export type PresignedUpload = {
  uploadUrl: string;
  fileUrl: string;
  expiresAt: Date;
};

/**
 * S3-compatible object storage (MinIO in development).
 *
 * Uploads go straight from the client to the object store with a short-lived
 * presigned PUT; the API never proxies media bytes. The object key is generated
 * server-side and bound to a `media_objects` row, so a signature cannot be fed
 * to a client to forge keys it did not request.
 */
export class StorageService {
  private readonly client: S3Client;
  private readonly endpoint: string;
  private readonly bucket: string;
  private readonly ttlSeconds: number;

  constructor(private readonly config: Config) {
    this.endpoint = config.S3_PUBLIC_ENDPOINT ?? config.S3_ENDPOINT;
    this.bucket = config.S3_BUCKET;
    this.ttlSeconds = config.MEDIA_PRESIGN_TTL_SECONDS;

    this.client = new S3Client({
      region: config.S3_REGION,
      endpoint: this.endpoint,
      forcePathStyle: config.S3_FORCE_PATH_STYLE,
      credentials: {
        accessKeyId: config.S3_ACCESS_KEY_ID,
        secretAccessKey: config.S3_SECRET_ACCESS_KEY,
      },
      // Only presign here; avoid retries complicating a purely local operation.
      maxAttempts: 2,
    });
  }

  /** Deterministic object key: `<owner>/<yyyy>/<mm>/<uuid>.<ext>`. */
  buildKey(ownerId: string, filename: string, contentType: string): string {
    const now = new Date();
    const extension = extensionFor(filename, contentType);
    return `${ownerId}/${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, '0')}/${randomUUID()}${extension}`;
  }

  /**
   * Presigns an upload. `contentType` and `size` are embedded in the signature
   * so the client cannot upload a larger or differently-typed object than the
   * one it declared.
   */
  async presignUpload(input: {
    key: string;
    contentType: string;
    sizeBytes: number;
  }): Promise<PresignedUpload> {
    const command = new PutObjectCommand({
      Bucket: this.bucket,
      Key: input.key,
      ContentType: input.contentType,
      ContentLength: input.sizeBytes,
    });

    const uploadUrl = await getSignedUrl(this.client, command, {
      expiresIn: this.ttlSeconds,
    });

    return {
      uploadUrl,
      fileUrl: this.objectUrl(input.key),
      expiresAt: new Date(Date.now() + this.ttlSeconds * 1000),
    };
  }

  /** Presigns a download for an object; used to serve private media. */
  async presignDownload(key: string, expiresIn = this.ttlSeconds): Promise<string> {
    const command = new GetObjectCommand({ Bucket: this.bucket, Key: key });
    return getSignedUrl(this.client, command, { expiresIn });
  }

  objectUrl(key: string): string {
    const base = this.endpoint.replace(/\/+$/, '');
    return this.config.S3_FORCE_PATH_STYLE
      ? `${base}/${this.bucket}/${key}`
      : `${base.replace(/^https?:\/\//, (scheme) => `${scheme}//${this.bucket}.`)}/${key}`;
  }

  async delete(key: string): Promise<void> {
    await this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: key }));
  }

  get bucketName(): string {
    return this.bucket;
  }
}

const MIME_EXTENSIONS: Record<string, string> = {
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp',
  'image/gif': '.gif',
  'video/mp4': '.mp4',
  'audio/mpeg': '.mp3',
  'application/pdf': '.pdf',
  'application/zip': '.zip',
  'text/plain': '.txt',
};

/** Preserves a short, safe extension from the original name, else derives one. */
function extensionFor(filename: string, contentType: string): string {
  const match = /\.([a-zA-Z0-9]{1,8})$/.exec(filename);
  if (match) return `.${match[1]!.toLowerCase()}`;
  return MIME_EXTENSIONS[contentType] ?? '';
}
