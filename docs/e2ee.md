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

Private halves live in `flutter_secure_storage` (Android Keystore), strictly
namespaced per account (`acct.<accountId>.e2ee_keys` and
`acct.<accountId>.e2ee_sessions`) so switching accounts on the same device can
never cross-load or overwrite another user's identity keys. The public halves
are published to `POST /api/v1/keys`; only the public halves reach the server.

### X3DH session setup

The initiator fetches `GET /api/v1/keys/{id}`. The server **consumes** one
one-time prekey with `DELETE ... RETURNING`, so two initiators can never receive
the same key. Publishing a *different* identity key (a reinstall) also deletes
every one-time prekey on file for that user: their private halves belonged to the
previous install, so handing one out would create a session the recipient could
never derive. Republishing the same identity keeps the supply intact.

The four DH outputs are concatenated and expanded with HKDF-SHA256:

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
and `opk` open a session, so an initiator attaches them to **every** message it
sends until the peer answers; after that they are omitted. Re-attaching lets a
peer that lost only its session state rebuild it from any later message, while
**cleared app data / reinstalls** are handled by the **key-epoch history
watermark** model below: when a fresh install publishes a new identity key with
`history_watermark: true`, the server increments `user_identity_keys.key_epoch`,
records `rotated_at`, discards orphaned one-time prekeys, and advances
`conversation_members.cleared_seq = last_seq` on all of that user's direct
conversations inside the same transaction. **Encrypted history is intentionally
not restored on a new or cleared device**, and the watermark ensures pre-rotation
ciphertexts are never re-synced as undecryptable stubs. The server validates
that `v`, `ik`, `ct`, `n`, and `m` are present and correctly typed, and rejects
a malformed prefixed body instead of delivering it as text
(`backend/src/lib/e2ee.ts`).

### Session identification and recovery

`ek` is also the session's identity, so a receiver can tell a repeated initiation
apart from a genuinely new one:

- A body whose `ek` matches a known session is decrypted under that session.
- A body with an unknown `ek` derives the responder side of X3DH and is adopted
  only if it authenticates. A replayed initiation cannot displace a working
  session, and a genuine re-initiation (the peer lost its state) is picked up
  instead of being ignored in favour of a stale chain.
- **Session glare** — both sides open a session before either reads the other's
  — is broken deterministically: the two initiating ephemeral keys are compared
  and the smaller one wins on both devices. The losing session is retained as an
  alternate so its in-flight messages still decrypt.
- Up to three sessions per peer are kept and persisted, which covers reordering
  within a session, a reinstall, and a simultaneous initiation.

A body that fails to decrypt leaves the receiving chain where it was: the
skip-ahead runs on a copy and is committed only after the GCM tag verifies.
Otherwise a corrupted or stale frame would advance the cursor past valid
messages and make them permanently unreadable.

## Ordering and the outbox

A retry must resend the *same* ciphertext: re-encrypting would advance the
ratchet, so the peer would be unable to decrypt it. The local outbox therefore
stores two values:

- `content` — the plaintext the user typed (what the bubble renders);
- `wire_content` — the ciphertext envelope actually written to the socket.

`flushOutbox` and `retry` always send `wire_content` when present.

Inbound bodies are decrypted in `ChatSocket._handleMessage` before persistence,
so the local mirror and every reader of it (bubbles, previews, search) only ever
see plaintext. Decryption happens once per message: a row that already holds its
plaintext is never decrypted again when the same message arrives over REST, so a
sync cannot advance the chain a second time. A body that cannot be decrypted is
stored as-is and rendered as a placeholder, so one unreadable message never
breaks a conversation.

### Background push notification decryption

When the Android app is terminated, upgraded clients (`push_version: 2`) receive
high-priority `data`-only FCM pushes carrying the `e2ee:v1:` ciphertext envelope
(or `content_omitted: "true"` when the envelope exceeds the 3,500-byte data
budget). `BackgroundPushHandler` decrypts the envelope on-device without ever
sending plaintext through FCM:

- **Main-isolate handoff:** If the app process is alive, the background isolate
  delegates via `IsolateNameServer` (`cpchat_main_fcm_port`) to the main isolate
  so only one isolate touches SQLite, in-memory `E2eeManager`, and rotating
  refresh tokens.
- **Cross-isolate lock & canonical path:** When terminated, `CpchatStorageDirsPlugin`
  resolves the canonical `noBackupFilesDir`, `TokenStore.forBackground()` reads
  Keystore with `resetOnError: false` (preventing wipes on Direct Boot / Keystore
  errors), and `<partitionDir>/.partition.lock` serializes against app startup.
- **Contiguous `seq` invariant:** Only `seq == effectiveCursor + 1` decrypts
  inline. Sequence gaps or `content_omitted: "true"` payloads run an
  authenticated `GET /api/v1/conversations/:id/sync?after_seq={cursor}` and
  decrypt strictly in ascending `seq` order; if offline, the ratchet is not
  advanced and the banner falls back to `"Encrypted message"`.
- **Crash-safe write order:** Decrypted plaintext is committed to Drift SQLite
  **before** persisting updated `acct.<id>.e2ee_sessions` (`deferSessionPersist:
  true` + `commitSessions()`). A kill between the two writes loses zero messages
  because `_alreadyReadable()` skips re-decryption on resume and the symmetric
  ratchet skips forward cleanly on message `i + 1`.

A failed decryption is reported once per message to the client log timeline
(tag `e2ee`) with `reason`, `message_id`, `conversation_id`, `sender_id`, the
exception type, and the non-secret session state (`present`, `initiator`,
`confirmed`, chain indices, alternate count). Plaintext and key material are
never logged. Send-side encryption failures are never downgraded to plaintext:
the message is refused and the user is told, because sending it unencrypted
would silently break the conversation's confidentiality.

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
  advance, but a message that arrives *after* a later one has been decrypted
  (beyond the current cursor) cannot be recovered. In-order and out-of-order
  delivery within the cursor window works; a gap noticed only after the chain has
  moved on does not. A failed decryption never moves the cursor, so a transient
  failure does not create such a gap.
- **No multi-device fan-out.** A user's other devices cannot read a session
  started with one device; multi-device E2EE needs per-device sessions.
- **Direct chats only.**

These are the concrete follow-ups for a full Double Ratchet, alongside group
sender keys and the safety-number UI.

## Testing

- `backend/test/keys.test.ts` — registry, atomic prekey consumption (including
  a concurrent-fetch race), envelope validation, and prekey cleanup on identity
  rotation.
- `mobile/test/e2ee_test.dart` — both directions, out-of-order delivery, replay
  rejection, tamper rejection, signature substitution, key export/import, peer
  re-initiation recovery, session glare, and non-destructive failed decryption.
- `mobile/test/e2ee_manager_test.dart` — persistence round-trips, restored
  sessions, stale-session recovery, and failure logging.
- `mobile/test/e2ee_delivery_test.dart` — a live `message` frame followed by a
  REST sync decrypts the body exactly once.
- `mobile/test/background_push_decrypt_test.dart` — terminated data-only FCM
  E2EE decryption, crash-safe DB-before-sessions commit order, gap-fill and
  >4 KB sync, multi-account isolation, and `.partition.lock` serialization.
