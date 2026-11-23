import { randomUUID } from 'node:crypto';
import type { Readable } from 'node:stream';

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

export type StoredObject = {
  body: Readable | Uint8Array;
  contentType?: string;
  contentLength?: number;
};

/**
 * The small slice of object-storage behaviour the API needs. The S3-backed
 * implementation is the default; an in-memory one lets the media-upload and
 * streaming tests run without a live MinIO container.
 */
interface ObjectStore {
  put(key: string, body: Uint8Array, contentType: string): Promise<void>;
  get(key: string): Promise<StoredObject>;
  remove(key: string): Promise<void>;
}

/**
 * S3-compatible object storage (MinIO in development).
 *
 * Two clients are kept deliberately separate:
 * - `internal` talks to `S3_ENDPOINT` (e.g. `http://minio:9000` inside Docker)
 *   and is used by the server for `PutObject`/`GetObject`/`DeleteObject`.
 * - `presign` signs URLs against `S3_PUBLIC_ENDPOINT`, the host the mobile
 *   client can actually reach. Presigning is a local computation, so this
 *   client never needs to open a connection.
 *
 * Because a phone often cannot reach MinIO directly, the API proxies uploads
 * (`POST /media/upload`) and downloads (`GET /media/*`) through the internal
 * client; presigned URLs remain available for callers that can reach storage.
 */
export class StorageService {
  private readonly internal: S3Client;
  private readonly presign: S3Client;
  private readonly bucket: string;
  private readonly ttlSeconds: number;
  private readonly publicEndpoint: string;
  private readonly store: ObjectStore;

  constructor(private readonly config: Config) {
    this.bucket = config.S3_BUCKET;
    this.ttlSeconds = config.MEDIA_PRESIGN_TTL_SECONDS;
    this.publicEndpoint = config.S3_PUBLIC_ENDPOINT ?? config.S3_ENDPOINT;

    this.internal = this.createClient(config.S3_ENDPOINT);
    this.presign = this.createClient(this.publicEndpoint);
    this.store =
      config.S3_DRIVER === 'memory'
        ? new InMemoryObjectStore()
        : {
            put: async (key, body, contentType) => {
              await this.internal.send(
                new PutObjectCommand({
                  Bucket: this.bucket,
                  Key: key,
                  Body: body,
                  ContentType: contentType,
                  ContentLength: body.length,
                }),
              );
            },
            get: async (key) => {
              const response = await this.internal.send(
                new GetObjectCommand({ Bucket: this.bucket, Key: key }),
              );
              if (!response.Body) {
                throw new Error(`Object ${key} has no body`);
              }
              return {
                body: response.Body as Readable,
                contentType: response.ContentType,
                contentLength: response.ContentLength,
              };
            },
            remove: async (key) => {
              await this.internal.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: key }));
            },
          };
  }

  private createClient(endpoint: string): S3Client {
    return new S3Client({
      region: this.config.S3_REGION,
      endpoint,
      forcePathStyle: this.config.S3_FORCE_PATH_STYLE,
      credentials: {
        accessKeyId: this.config.S3_ACCESS_KEY_ID,
        secretAccessKey: this.config.S3_SECRET_ACCESS_KEY,
      },
      // Presigning is local; avoiding retries keeps it a pure computation.
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

    const uploadUrl = await getSignedUrl(this.presign, command, {
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
    return getSignedUrl(this.presign, command, { expiresIn });
  }

  /** Writes bytes through the internal client (the API-proxied upload path). */
  async putObject(key: string, body: Uint8Array, contentType: string): Promise<void> {
    await this.store.put(key, body, contentType);
  }

  /** Reads an object through the internal client for a streamed download. */
  async getObject(key: string): Promise<StoredObject> {
    return this.store.get(key);
  }

  objectUrl(key: string): string {
    const base = this.publicEndpoint.replace(/\/+$/, '');
    return this.config.S3_FORCE_PATH_STYLE
      ? `${base}/${this.bucket}/${key}`
      : `${base.replace(/^https?:\/\//, (scheme) => `${scheme}//${this.bucket}.`)}/${key}`;
  }

  async delete(key: string): Promise<void> {
    await this.store.remove(key);
  }

  get bucketName(): string {
    return this.bucket;
  }
}

/** Test-only store: keeps uploaded bytes in the process. */
class InMemoryObjectStore implements ObjectStore {
  private readonly objects = new Map<string, { body: Uint8Array; contentType: string }>();

  async put(key: string, body: Uint8Array, contentType: string): Promise<void> {
    this.objects.set(key, { body, contentType });
  }

  async get(key: string): Promise<StoredObject> {
    const object = this.objects.get(key);
    if (!object) {
      throw new Error(`Object ${key} not found`);
    }
    return {
      body: object.body,
      contentType: object.contentType,
      contentLength: object.body.length,
    };
  }

  async remove(key: string): Promise<void> {
    this.objects.delete(key);
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
