# End-to-end encryption

Direct-chat text messages are end-to-end encrypted. The server relays ciphertext
and never holds a private key or a message plaintext.

## What is and is not encrypted

| Content | Encrypted | Notes |
| --- | --- | --- |
| Direct-chat `text` bodies | Yes | `e2ee:v1:` envelope |
| Group-chat text | No | Out of scope this phase; groups share one conversation key model |
| Images and files | No (body) | Object key + caption; bytes protected by access-controlled storage |
| Metadata | No | Sender, recipient, `seq`, timestamps, ciphertext length |

Group E2EE requires managing a sender key per group and distributing it on every
membership change. That is a separate design (Signal's sender keys) and is
deliberately not approximated here.

## Protocol

### Keys

Each device generates, once:

- an **X25519 identity key** (long-term),
- an **Ed25519 signing key** (proves a prekey belongs to the identity),
- one **signed prekey** (X25519, signed by the signing key),
- a batch of **one-time prekeys** (X25519).

Private halves live in `flutter_secure_storage` (Android Keystore). The public
halves are published to `POST /api/v1/keys`; only the public halves reach the
server.

### X3DH session setup

The initiator fetches `GET /api/v1/keys/{id}`. The server **consumes** one
one-time prekey with `DELETE ... RETURNING`, so two initiators can never receive
the same key. The four DH outputs are concatenated and expanded with HKDF-SHA256:

```
DH1 = DH(IK_A, SPK_B)      // identity A, signed prekey B
DH2 = DH(EK_A, IK_B)       // ephemeral A, identity B
DH3 = DH(EK_A, SPK_B)      // ephemeral A, signed prekey B
DH4 = DH(EK_A, OPK_B)      // ephemeral A, one-time prekey B (optional)

root = HKDF-SHA256(DH1 ‖ DH2 ‖ DH3 ‖ DH4, info="cpchat-x3dh-v1")
sendKey = HKDF-SHA256(root, info="cpchat-chain-<initiator|responder>-send")
```

The initiator's sending chain and the responder's receiving chain are derived
from the same `info` label, and vice versa, so both sides agree while the two
directions stay independent.

### Symmetric ratchet

Each direction keeps its own chain key. For every message:

```
messageKey = HMAC-SHA256(chainKey, 0x01)
nextChain  = HMAC-SHA256(chainKey, 0x02)
```

The message is encrypted with AES-256-GCM under `messageKey` and a fresh random
12-byte nonce. Distinct labels keep the message key and next chain key
unrelated. A leaked message key cannot recover earlier keys (forward secrecy per
chain), and advancing the chain means a replayed envelope is rejected because its
index is behind the current receiving position.

The envelope carries the sender's chain index `i`. A receiver advances past
messages it never saw, which tolerates loss within a chain, and rejects an index
below its cursor, which stops replay.

### Envelope

```json
{
  "v": 1,
  "ik": "<sender identity public key, base64>",
  "ek": "<sender ephemeral public key, base64>",
  "spk": 42,
  "opk": 43,
  "i": 0,
  "ct": "<AES-GCM ciphertext, base64>",
  "n": "<12-byte nonce, base64>",
  "m": "<16-byte GCM tag, base64>"
}
```

The body stored in the message is `e2ee:v1:` followed by this JSON. `ek`, `spk`,
and `opk` are only present on the message that opens a session; a reply omits
them because the peer already holds the session. The server validates that `v`,
`ik`, `ct`, `n`, and `m` are present and correctly typed, and rejects a malformed
prefixed body instead of delivering it as text (`backend/src/lib/e2ee.ts`).

## Ordering and the outbox

A retry must resend the *same* ciphertext: re-encrypting would advance the
ratchet, so the peer would be unable to decrypt it. The local outbox therefore
stores two values:

- `content` — the plaintext the user typed (what the bubble renders);
- `wire_content` — the ciphertext envelope actually written to the socket.

`flushOutbox` and `retry` always send `wire_content` when present.

Inbound bodies are decrypted in `ChatSocket._handleMessage` before persistence,
so the local mirror and every reader of it (bubbles, previews, search) only ever
see plaintext. A body that cannot be decrypted is stored as-is and rendered as a
placeholder, so one unreadable message never breaks a conversation.

## Trust on first use

There is no out-of-band identity verification UI yet. The client verifies the
signed-prekey signature against the fetched signing key, which stops a malicious
server from substituting a prekey, but it does not prove the signing key belongs
to the person. The next step is a safety-number screen (a hash of both identity
keys) that users can compare in person.

## Deliberate limits

This is a documented subset of the Double Ratchet, chosen so it can be reviewed
and tested rather than approximated:

- **No DH ratchet.** Chains are not re-keyed on each round-trip, so
  *post-compromise* security (healing after a key leak) is weaker than Signal's.
- **No skipped-message key storage.** Loss within a chain is tolerated by index
  advance, but a message that arrives after the chain has moved past it (beyond
  the current cursor) cannot be decrypted.
- **No multi-device fan-out.** A user's other devices cannot read a session
  started with one device; multi-device E2EE needs per-device sessions.
- **Direct chats only.**

These are the concrete follow-ups for a full Double Ratchet, alongside group
sender keys and the safety-number UI.

## Testing

- `backend/test/keys.test.ts` — registry, atomic prekey consumption (including
  a concurrent-fetch race), envelope validation.
- `mobile/test/e2ee_test.dart` — both directions, out-of-order delivery, replay
  rejection, tamper rejection, signature substitution, key export/import.
- `mobile/test/e2ee_manager_test.dart` — persistence round-trips and restored
  sessions.
