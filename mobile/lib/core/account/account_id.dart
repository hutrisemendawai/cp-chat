import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable, opaque local partition identifier derived from a server `userId`.
///
/// Uses the first 16 lowercase hex characters of `SHA-256("cpchat.account.v1:" + userId)`
/// so raw user IDs and PII never appear in filesystem paths or notification tags.
String accountIdForUser(String userId) {
  final digest = sha256.convert(utf8.encode('cpchat.account.v1:$userId'));
  return digest.toString().substring(0, 16);
}
