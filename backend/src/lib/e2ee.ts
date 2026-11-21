/**
 * End-to-end encryption envelope (v1).
 *
 * The server relays ciphertext and must never be able to read a message. A
 * direct message body is therefore a JSON envelope stored as the message
 * `content`, prefixed with `e2ee:v1:` so:
 *   - Phase 1-3 plaintext clients keep working (their content has no prefix);
 *   - the server can distinguish an encrypted body from a plaintext one without
 *     parsing it;
 *   - a future version can change the shape without ambiguity.
 *
 * What the server sees is only: sender, recipient, timestamps, `seq`, and the
 * length of the ciphertext. Everything else (the plaintext, the session state,
 * the ratchet keys) never leaves the device.
 *
 * The envelope carries the X3DH initial message on the first frame of a
 * session (the sender's identity key, ephemeral key, the prekey ids it used,
 * and the ciphertext) and a symmetric-key ratchet message afterwards. This is
 * deliberately a *minimal* Double-Ratchet: it provides forward secrecy on the
 * sending chain, and the per-message random nonce plus AES-256-GCM gives
 * integrity. A full asynchronous ratchet (skipped/missing-key handling for
 * out-of-order delivery) is documented as the next step in docs/e2ee.md rather
 * than approximated here.
 */

export const E2EE_PREFIX = 'e2ee:v1:';

export type E2eeEnvelope = {
  /** Always 1 for this format. */
  v: 1;
  /** Sender identity public key (X25519, base64) so the recipient can pin it. */
  ik: string;
  /**
   * Sender ephemeral public key (X25519, base64). Present only on the message
   * that opens a session; replies omit it because the peer already has one.
   */
  ek?: string;
  /** Signed prekey id used from the recipient's bundle (initiation only). */
  spk?: number;
  /** One-time prekey id used from the recipient's bundle, if any. */
  opk?: number;
  /** Position in the sender's chain. */
  i: number;
  /** Base64 AES-256-GCM ciphertext. */
  ct: string;
  /** Base64 12-byte nonce. */
  n: string;
  /** Base64 AES-256-GCM authentication tag. */
  m: string;
};

export type ParsedContent =
  | { encrypted: false; plaintext: string }
  | { encrypted: true; envelope: E2eeEnvelope };

/**
 * Parses a message body. Anything without the prefix is treated as plaintext
 * (Phase 1-3 clients, or a deliberate unencrypted fallback), so this never
 * throws for the server's purposes; a malformed *prefixed* body is rejected so
 * a corrupt envelope is not silently delivered as text.
 */
export function parseMessageContent(content: string): ParsedContent {
  if (!content.startsWith(E2EE_PREFIX)) {
    return { encrypted: false, plaintext: content };
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(content.slice(E2EE_PREFIX.length));
  } catch {
    throw new Error('malformed_e2ee_envelope');
  }

  if (!decoded || typeof decoded !== 'object') {
    throw new Error('malformed_e2ee_envelope');
  }
  const envelope = decoded as Record<string, unknown>;
  for (const field of ['ik', 'ct', 'n', 'm'] as const) {
    if (typeof envelope[field] !== 'string' || envelope[field].length === 0) {
      throw new Error('malformed_e2ee_envelope');
    }
  }
  if (envelope.v !== 1) throw new Error('unsupported_e2ee_version');
  if (envelope.i !== undefined && typeof envelope.i !== 'number') {
    throw new Error('malformed_e2ee_envelope');
  }
  // X3DH initiation fields travel together, or not at all.
  if (envelope.ek !== undefined && typeof envelope.ek !== 'string') {
    throw new Error('malformed_e2ee_envelope');
  }
  if (envelope.spk !== undefined && typeof envelope.spk !== 'number') {
    throw new Error('malformed_e2ee_envelope');
  }
  if (envelope.opk !== undefined && typeof envelope.opk !== 'number') {
    throw new Error('malformed_e2ee_envelope');
  }

  return {
    encrypted: true,
    envelope: {
      v: 1,
      ik: envelope.ik as string,
      ek: envelope.ek as string | undefined,
      spk: envelope.spk as number | undefined,
      opk: envelope.opk as number | undefined,
      i: (envelope.i as number | undefined) ?? 0,
      ct: envelope.ct as string,
      n: envelope.n as string,
      m: envelope.m as string,
    },
  };
}

/** True when the body is an E2EE envelope, without parsing it. */
export function isEncryptedContent(content: string): boolean {
  return content.startsWith(E2EE_PREFIX);
}

/**
 * Only text bodies are encrypted. Media messages store an object key plus an
 * optional caption, and the bytes themselves are already protected by
 * access-controlled object storage; encrypting the key in the body would break
 * the thumbnail pipeline. This mirrors Signal, which encrypts the attachment
 * *key* rather than the message body once a media pipeline is in place.
 */
export function isEncryptableType(type: 'text' | 'image' | 'file'): boolean {
  return type === 'text';
}

export function buildEnvelope(envelope: E2eeEnvelope): string {
  return `${E2EE_PREFIX}${JSON.stringify(envelope)}`;
}
