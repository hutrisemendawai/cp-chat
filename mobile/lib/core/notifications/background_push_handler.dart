import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show IsolateNameServer;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../account/account_id.dart';
import '../account/account_paths.dart';
import '../account/account_registry.dart';
import '../account/account_store.dart';
import '../account/legacy_migration.dart';
import '../account/partition_guard.dart';
import '../account/partition_lock.dart';
import '../crypto/e2ee_manager.dart';
import '../crypto/e2ee_service.dart';
import '../database/app_database.dart';
import '../database/chat_dao.dart';
import '../logging/app_logger.dart';
import '../models/models.dart';
import '../network/api_client.dart';
import '../storage/app_dirs.dart';
import '../storage/token_store.dart';
import 'fcm_service.dart';
import 'local_notification_service.dart';
import 'notification_policy.dart';

/// `IsolateNameServer` port name registered by the main isolate while the app
/// process is alive so headless FCM pushes are delegated to the live main
/// isolate (single owner of SQLite, E2EE ratchets, and rotating refresh tokens).
const String kMainIsolateFcmPortName = 'cpchat_main_fcm_port';

/// Outcome of handling a background FCM push (exposed for tests and logging).
enum BackgroundPushOutcome {
  ignoredOsRendered,
  droppedInvalid,
  delegatedToMainIsolate,
  droppedAccountMismatch,
  droppedWipePending,
  droppedIntegrityMismatch,
  suppressedPolicy,
  suppressedCleared,
  suppressedDuplicate,
  shownDecrypted,
  shownPlaintext,
  shownFallback,
  shownCallInvite,
  cancelledCallNotification,
  droppedExpiredCall,
}

/// Non-secret diagnostic reason recorded when a background push falls back to
/// a generic placeholder instead of decrypted text.
enum BackgroundFallbackReason {
  layoutUnmigrated,
  noBackupDirUnavailable,
  dbMissing,
  lockTimeout,
  noLocalKeys,
  decryptFailed,
  syncFailed,
  syncGapTooLarge,
  syncDiscontinuous,
  staleSeq,
}

/// Parsed fields of a `push_schema: "2"` (or legacy data-only) FCM payload.
@immutable
class ParsedFcmMessage {
  const ParsedFcmMessage({
    required this.conversationId,
    required this.conversationType,
    required this.conversationName,
    required this.msgType,
    required this.createdAt,
    this.pushSchema,
    this.messageId,
    this.clientMsgId,
    this.seq,
    this.senderId,
    this.senderName,
    this.recipientUserId,
    this.content,
    this.contentOmitted = false,
  });

  final String? pushSchema;
  final String conversationId;
  final String conversationType;
  final String conversationName;
  final String? messageId;
  final String? clientMsgId;
  final int? seq;
  final String? senderId;
  final String? senderName;
  final String? recipientUserId;
  final String msgType;
  final DateTime createdAt;
  final String? content;
  final bool contentOmitted;

  bool get isGroup => conversationType == 'group';
  bool get isV2 => pushSchema == '2';

  static ParsedFcmMessage? tryParse(Map<String, dynamic> data) {
    final conversationId = _nonEmpty(data['conversation_id']);
    if (conversationId == null) return null;

    final rawType = _nonEmpty(data['msg_type']) ?? _nonEmpty(data['type']) ?? 'text';
    final convType = _nonEmpty(data['conversation_type']) ?? 'direct';
    final rawSeq = _nonEmpty(data['seq']);
    final rawCreatedAt = _nonEmpty(data['created_at']);
    final parsedCreatedAt = rawCreatedAt == null
        ? DateTime.now().toUtc()
        : (DateTime.tryParse(rawCreatedAt)?.toUtc() ?? DateTime.now().toUtc());

    final contentOmitted = _nonEmpty(data['content_omitted'])?.toLowerCase() == 'true';
    final rawContent = data['content']?.toString();

    return ParsedFcmMessage(
      pushSchema: _nonEmpty(data['push_schema']),
      conversationId: conversationId,
      conversationType: convType,
      conversationName: data['conversation_name']?.toString() ?? '',
      messageId: _nonEmpty(data['message_id']),
      clientMsgId: _nonEmpty(data['client_msg_id']),
      seq: rawSeq == null ? null : int.tryParse(rawSeq),
      senderId: _nonEmpty(data['sender_id']),
      senderName: _nonEmpty(data['sender_name']),
      recipientUserId: _nonEmpty(data['recipient_user_id']),
      msgType: rawType,
      createdAt: parsedCreatedAt,
      content: rawContent,
      contentOmitted: contentOmitted,
    );
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}

/// Processes high-priority `data`-only FCM pushes when the app is terminated.
///
/// Key safety invariants:
/// 1. If the main isolate is alive (`IsolateNameServer` port registered),
///    delegates the push to the main isolate so only one isolate ever touches
///    SQLite, in-memory `E2eeManager`, and single-use rotating refresh tokens.
/// 2. Uses `TokenStore.forBackground()` (`resetOnError: false`) so transient
///    Keystore / Direct Boot errors never wipe tokens or E2EE private keys.
/// 3. Resolves the canonical Android `noBackupFilesDir` strictly (via
///    `CpchatStorageDirsPlugin`) and never opens a new/split DB file.
/// 4. Serializes DB + ratchet access under `<partitionDir>/.partition.lock`
///    and an in-isolate queue.
/// 5. Enforces contiguous `seq == cursor + 1` decryption (using `/sync` for
///    gaps or >4 KB `content_omitted` payloads) and **commits SQLite BEFORE
///    persisting `acct.<id>.e2ee_sessions`** so an OS kill between writes loses
///    zero messages.
class BackgroundPushHandler {
  BackgroundPushHandler({
    TokenStore Function()? tokenStoreFactory,
    AppDirs Function()? appDirsFactory,
    ApiClient Function(TokenStore store, String? deviceId)? apiClientFactory,
    Future<MessageNotificationSink> Function()? notificationSinkFactory,
    E2eeService Function()? e2eeServiceFactory,
    SendPort? Function(String name)? portLookup,
    this.mainIsolateHandoffTimeout = const Duration(seconds: 2),
    this.lockTimeout = const Duration(seconds: 5),
    this.maxSyncPages = 3,
    this.syncPageLimit = 200,
    this.syncBudget = const Duration(seconds: 12),
  })  : _tokenStoreFactory = tokenStoreFactory ?? TokenStore.forBackground,
        _appDirsFactory = appDirsFactory ?? AppDirs.new,
        _apiClientFactory = apiClientFactory ?? _defaultApiClient,
        _notificationSinkFactory =
            notificationSinkFactory ?? _defaultNotificationSink,
        _e2eeServiceFactory = e2eeServiceFactory ?? E2eeService.new,
        _portLookup = portLookup ?? IsolateNameServer.lookupPortByName;

  static final BackgroundPushHandler shared = BackgroundPushHandler();

  static const String diagFileName = 'bg_push_diag.jsonl';
  static const String bgE2eeMarkerFileName = '.bg_e2ee_ts';
  static const int maxDiagLines = 50;

  final TokenStore Function() _tokenStoreFactory;
  final AppDirs Function() _appDirsFactory;
  final ApiClient Function(TokenStore store, String? deviceId) _apiClientFactory;
  final Future<MessageNotificationSink> Function() _notificationSinkFactory;
  final E2eeService Function() _e2eeServiceFactory;
  final SendPort? Function(String name) _portLookup;
  final Duration mainIsolateHandoffTimeout;
  final Duration lockTimeout;
  final int maxSyncPages;
  final int syncPageLimit;
  final Duration syncBudget;

  /// In-isolate FIFO queue so rapid back-to-back FCM pushes execute strictly
  /// one at a time.
  Future<void> _queue = Future<void>.value();

  static ApiClient _defaultApiClient(TokenStore store, String? deviceId) =>
      ApiClient(
        store,
        deviceId: deviceId,
        clearTokensOnRefreshFailure: false,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
      );

  /// Reads the marker timestamp written whenever the background isolate
  /// commits updated E2EE ratchet sessions.
  static Future<String?> readBackgroundE2eeMarker(Directory partitionDir) async {
    try {
      final file = File(p.join(partitionDir.path, bgE2eeMarkerFileName));
      if (!await file.exists()) return null;
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeBackgroundE2eeMarker(Directory partitionDir) async {
    try {
      final file = File(p.join(partitionDir.path, bgE2eeMarkerFileName));
      await file.writeAsString(
        '${DateTime.now().toUtc().microsecondsSinceEpoch}',
        flush: true,
      );
    } catch (_) {}
  }

  /// Drains bounded non-secret background push diagnostic entries recorded
  /// while the app was closed and forwards them through [logger].
  static Future<void> drainDiagnostics(
    Directory partitionDir,
    AppLogger logger,
  ) async {
    final file = File(p.join(partitionDir.path, diagFileName));
    try {
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      await file.delete();
      for (final raw in lines) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            final reason = decoded['fallback_reason']?.toString() ?? 'unknown';
            logger.warn(
              'fcm_bg_diag',
              'background push fallback: $reason',
              meta: decoded.map((k, v) => MapEntry(k, v)),
            );
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> _recordDiagnostic(
    Directory? partitionDir, {
    required ParsedFcmMessage parsed,
    required BackgroundPushOutcome outcome,
    BackgroundFallbackReason? fallbackReason,
    String? decryptReason,
  }) async {
    if (partitionDir == null) return;
    try {
      if (!await partitionDir.exists()) return;
      final file = File(p.join(partitionDir.path, diagFileName));
      final entry = jsonEncode(<String, Object?>{
        'ts': DateTime.now().toUtc().toIso8601String(),
        'outcome': outcome.name,
        if (fallbackReason != null) 'fallback_reason': fallbackReason.name,
        if (decryptReason != null && decryptReason.isNotEmpty)
          'decrypt_reason': decryptReason,
        'conversation_id': parsed.conversationId,
        if (parsed.seq != null) 'seq': parsed.seq,
        if (parsed.pushSchema != null) 'push_schema': parsed.pushSchema,
        'content_omitted': parsed.contentOmitted,
      });
      List<String> lines = [];
      if (await file.exists()) {
        lines = (await file.readAsLines())
            .where((l) => l.trim().isNotEmpty)
            .toList();
      }
      lines.add(entry);
      if (lines.length > maxDiagLines) {
        lines = lines.sublist(lines.length - maxDiagLines);
      }
      await file.writeAsString('${lines.join('\n')}\n', flush: true);
    } catch (_) {}
  }

  static String? _extractDecryptReason(AppLogger bgLogger) {
    for (var i = bgLogger.entries.length - 1; i >= 0; i -= 1) {
      final entry = bgLogger.entries[i];
      if (entry.tag == 'e2ee') {
        final reason = entry.meta?['reason']?.toString();
        if (reason != null && reason.isNotEmpty) return reason;
      }
    }
    return null;
  }

  static Future<MessageNotificationSink> _defaultNotificationSink() async {
    final service = LocalNotificationService();
    await service.initialize(checkLaunchDetails: false);
    return service;
  }

  static const Set<String> _callPushTypes = {
    'call_invite',
    'call_cancel',
    'call_ended',
    'group_call_started',
  };

  static bool isCallPushType(String type) => _callPushTypes.contains(type);

  Future<BackgroundPushOutcome> _handleCallPush(
    Map<String, dynamic> data,
    String type,
  ) async {
    final callId = data['call_id']?.toString().trim() ?? '';
    final conversationId = data['conversation_id']?.toString().trim() ?? '';
    if (callId.isEmpty || conversationId.isEmpty) {
      return BackgroundPushOutcome.droppedInvalid;
    }

    // Delegate to the live main isolate whenever the app process is in memory.
    if (await _tryDelegateToMainIsolate(data)) {
      return BackgroundPushOutcome.delegatedToMainIsolate;
    }

    // Terminated state: verify session + account ownership without touching SQLite.
    final tokenStore = _tokenStoreFactory();
    final access = await tokenStore.readAccessToken();
    final refresh = await tokenStore.readRefreshToken();
    final hasSession =
        (access != null && access.isNotEmpty) || (refresh != null && refresh.isNotEmpty);
    final userId = await tokenStore.readUserId();
    var activeAccountId = await tokenStore.readActiveAccountId();
    if ((activeAccountId == null || activeAccountId.isEmpty) &&
        userId != null &&
        userId.isNotEmpty) {
      activeAccountId = accountIdForUser(userId);
    }

    final recipientUserId = data['recipient_user_id']?.toString().trim();
    if (!shouldHandleFcmForAccount(
          recipientUserId: recipientUserId,
          activeAccountId: activeAccountId,
          hasSession: hasSession,
        ) ||
        userId == null ||
        userId.isEmpty ||
        activeAccountId == null ||
        activeAccountId.isEmpty) {
      return BackgroundPushOutcome.droppedAccountMismatch;
    }

    final sink = await _notificationSinkFactory();

    if (type == 'call_cancel' || type == 'call_ended') {
      if (sink is LocalNotificationService) {
        await sink.cancelCallNotification(callId);
      }
      return BackgroundPushOutcome.cancelledCallNotification;
    }

    // Respect Do Not Disturb preference for incoming rings and group call alerts.
    final cachedUser = await tokenStore.readUser();
    if (cachedUser?.status == 'dnd') {
      return BackgroundPushOutcome.suppressedPolicy;
    }

    if (type == 'call_invite') {
      final expiresRaw = int.tryParse(data['expires_at']?.toString().trim() ?? '');
      if (expiresRaw != null &&
          DateTime.now().toUtc().millisecondsSinceEpoch >= expiresRaw) {
        return BackgroundPushOutcome.droppedExpiredCall;
      }
      final callerId = data['caller_id']?.toString().trim() ?? '';
      final callerName = data['caller_name']?.toString().trim().isNotEmpty == true
          ? data['caller_name']!.toString().trim()
          : 'Incoming call';
      final mediaType = data['media_type']?.toString().trim() ?? 'voice';

      if (sink is LocalNotificationService) {
        await sink.showIncomingCallNotification(
          callId: callId,
          conversationId: conversationId,
          callerId: callerId,
          callerName: callerName,
          mediaType: mediaType,
          accountId: activeAccountId,
          expiresAtMs: expiresRaw,
        );
      } else {
        await sink.showMessageNotification(
          conversationId: conversationId,
          title: callerName,
          body: mediaType == 'video' ? 'Incoming video call' : 'Incoming voice call',
          messageId: callId,
          accountId: activeAccountId,
        );
      }
      return BackgroundPushOutcome.shownCallInvite;
    }

    // Lightweight group call announcement ("Alice started a group call in <Group>").
    final callerName = data['caller_name']?.toString().trim().isNotEmpty == true
        ? data['caller_name']!.toString().trim()
        : 'Someone';
    final groupName = data['conversation_name']?.toString().trim().isNotEmpty == true
        ? data['conversation_name']!.toString().trim()
        : 'Group';
    final mediaType = data['media_type']?.toString().trim() == 'video' ? 'video' : 'voice';
    await sink.showMessageNotification(
      conversationId: conversationId,
      title: groupName,
      body: '$callerName started a group $mediaType call',
      messageId: callId,
      accountId: activeAccountId,
    );
    return BackgroundPushOutcome.shownCallInvite;
  }

  Future<BackgroundPushOutcome> handle(RemoteMessage message) {
    return handleData(
      message.data,
      hasNotificationBlock: message.notification != null,
    );
  }

  Future<BackgroundPushOutcome> handleData(
    Map<String, dynamic> data, {
    bool hasNotificationBlock = false,
  }) {
    final run = _queue.then(
      (_) => _handleSingle(data, hasNotificationBlock: hasNotificationBlock),
    );
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<BackgroundPushOutcome> _handleSingle(
    Map<String, dynamic> data, {
    required bool hasNotificationBlock,
  }) async {
    // 1. Legacy v1 payload: Android OS already painted the notification block.
    if (hasNotificationBlock) {
      return BackgroundPushOutcome.ignoredOsRendered;
    }

    // 1b. Call signaling fast-path (`call_invite`, `call_cancel`, `call_ended`,
    //     `group_call_started`) runs BEFORE message parsing / SQLite lock for
    //     sub-second terminated-state wake-up while enforcing account isolation.
    final rawPushType = data['type']?.toString().trim() ?? '';
    if (isCallPushType(rawPushType)) {
      return _handleCallPush(data, rawPushType);
    }

    // 2. Parse metadata.
    final parsed = ParsedFcmMessage.tryParse(data);
    if (parsed == null) {
      return BackgroundPushOutcome.droppedInvalid;
    }

    // 3. If the main isolate is alive, delegate to it so only one isolate owns
    //    SQLite, E2eeManager, and rotating refresh tokens.
    if (await _tryDelegateToMainIsolate(data)) {
      return BackgroundPushOutcome.delegatedToMainIsolate;
    }

    // 4. Verify active session, account isolation, policy, wipe state, layout.
    final tokenStore = _tokenStoreFactory();
    final access = await tokenStore.readAccessToken();
    final refresh = await tokenStore.readRefreshToken();
    final hasSession =
        (access != null && access.isNotEmpty) || (refresh != null && refresh.isNotEmpty);
    final userId = await tokenStore.readUserId();
    var activeAccountId = await tokenStore.readActiveAccountId();
    if ((activeAccountId == null || activeAccountId.isEmpty) &&
        userId != null &&
        userId.isNotEmpty) {
      activeAccountId = accountIdForUser(userId);
    }

    if (!shouldHandleFcmForAccount(
          recipientUserId: parsed.recipientUserId,
          activeAccountId: activeAccountId,
          hasSession: hasSession,
        ) ||
        userId == null ||
        userId.isEmpty ||
        activeAccountId == null ||
        activeAccountId.isEmpty) {
      return BackgroundPushOutcome.droppedAccountMismatch;
    }

    final cachedUser = await tokenStore.readUser();
    if (!NotificationPolicy.shouldNotify(
      senderId: parsed.senderId,
      selfId: userId,
      selfStatus: cachedUser?.status,
      appResumed: false,
      activeConversationId: null,
      conversationId: parsed.conversationId,
    )) {
      return BackgroundPushOutcome.suppressedPolicy;
    }

    final pendingWipes = await AccountRegistry(tokenStore).pendingWipes();
    if (pendingWipes.contains(activeAccountId)) {
      return BackgroundPushOutcome.droppedWipePending;
    }

    final layout = await tokenStore.readValue(LegacyMigration.layoutKey);
    final hasExplicitOldLayout = layout != null &&
        layout.isNotEmpty &&
        layout != LegacyMigration.layoutVersion;
    if (hasExplicitOldLayout) {
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }
    final layoutUnset = layout == null || layout.isEmpty;

    // 5. Resolve canonical noBackupDir strictly (never split the DB).
    final dirs = _appDirsFactory();
    final noBackupRoot = await dirs.noBackupDirStrict(tokenStore: tokenStore);
    if (noBackupRoot == null) {
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }

    final paths = AccountPaths(
      accountId: activeAccountId,
      noBackupRoot: noBackupRoot,
      cacheRoot: noBackupRoot,
    );
    if (!await paths.dbFile.exists()) {
      await _recordDiagnostic(
        paths.partitionDir,
        parsed: parsed,
        outcome: BackgroundPushOutcome.shownFallback,
        fallbackReason: layoutUnset
            ? BackgroundFallbackReason.layoutUnmigrated
            : BackgroundFallbackReason.dbMissing,
      );
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }

    // 6. Phase 1 under `.partition.lock`: verify integrity, handle Case 1
    //    inline or Case 3 stale lookups, or return a `_SyncPlan` for Case 2 so
    //    network `/sync` runs WITHOUT holding `.partition.lock`.
    _PartitionResult result;
    try {
      result = await PartitionLock.withLock<_PartitionResult>(
        paths.partitionDir,
        () => _processUnderLock(
          parsed: parsed,
          paths: paths,
          tokenStore: tokenStore,
          userId: userId,
          activeAccountId: activeAccountId!,
        ),
        timeout: lockTimeout,
      );
    } catch (error) {
      debugPrint('BackgroundPushHandler partition lock/processing failed: $error');
      await _recordDiagnostic(
        paths.partitionDir,
        parsed: parsed,
        outcome: BackgroundPushOutcome.shownFallback,
        fallbackReason: BackgroundFallbackReason.lockTimeout,
      );
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }

    // Case 2: network `/sync` executes OUTSIDE `.partition.lock`, then
    // re-acquires `.partition.lock` briefly to decrypt and commit contiguously.
    if (result.syncPlan != null) {
      final plan = result.syncPlan!;
      final fetched = await _fetchSyncPages(
        parsed: parsed,
        plan: plan,
        tokenStore: tokenStore,
      );
      try {
        result = await PartitionLock.withLock<_PartitionResult>(
          paths.partitionDir,
          () => _applySyncedMessagesUnderLock(
            parsed: parsed,
            plan: plan,
            fetched: fetched,
            paths: paths,
            tokenStore: tokenStore,
            userId: userId,
            activeAccountId: activeAccountId!,
          ),
          timeout: lockTimeout,
        );
      } catch (error) {
        debugPrint('BackgroundPushHandler sync apply failed: $error');
        await _recordDiagnostic(
          paths.partitionDir,
          parsed: parsed,
          outcome: BackgroundPushOutcome.shownFallback,
          fallbackReason: BackgroundFallbackReason.lockTimeout,
        );
        await _showNotification(
          parsed: parsed,
          accountId: activeAccountId,
          isGroup: plan.isGroup,
          title: plan.title,
          displayContent: _fallbackDisplayContent(parsed),
        );
        return BackgroundPushOutcome.shownFallback;
      }
    }

    if (result.abortOutcome != null) {
      return result.abortOutcome!;
    }

    if (result.outcome == BackgroundPushOutcome.shownFallback) {
      await _recordDiagnostic(
        paths.partitionDir,
        parsed: parsed,
        outcome: result.outcome,
        fallbackReason: result.fallbackReason,
        decryptReason: result.decryptReason,
      );
    }

    await _showNotification(
      parsed: parsed,
      accountId: activeAccountId,
      isGroup: result.isGroup,
      title: result.title,
      displayContent: result.displayContent,
    );
    return result.outcome;
  }

  Future<bool> _tryDelegateToMainIsolate(Map<String, dynamic> data) async {
    final port = _portLookup(kMainIsolateFcmPortName);
    if (port == null) return false;

    final reply = ReceivePort();
    try {
      port.send(<String, dynamic>{
        'data': Map<String, dynamic>.from(data),
        'replyPort': reply.sendPort,
      });
      final ack = await reply.first.timeout(mainIsolateHandoffTimeout);
      return ack == true;
    } catch (_) {
      return false;
    } finally {
      reply.close();
    }
  }

  Future<_PartitionResult> _processUnderLock({
    required ParsedFcmMessage parsed,
    required AccountPaths paths,
    required TokenStore tokenStore,
    required String userId,
    required String activeAccountId,
  }) async {
    final accountStore = AccountStore(tokenStore, activeAccountId);
    final db = AppDatabase.forFile(paths.dbFile);
    try {
      // Read-only partition integrity check: never recreate or mutate meta.
      final dbOwner = await db.readMeta(PartitionGuard.ownerUserIdKey);
      final dbPartId = await db.readMeta(PartitionGuard.partitionIdKey);
      final storePartId = await accountStore.readPartitionId();
      if (dbOwner != userId ||
          dbPartId == null ||
          dbPartId.isEmpty ||
          storePartId == null ||
          storePartId.isEmpty ||
          dbPartId != storePartId) {
        return const _PartitionResult.abort(
          BackgroundPushOutcome.droppedIntegrityMismatch,
        );
      }

      final dao = ChatDao(db);
      final conv = await dao.conversation(parsed.conversationId);
      // A terminated app may receive its very first message from a non-friend:
      // persist a provisional conversation row atomically with the message so
      // reopening the Chats tab already shows the chat + unread badge offline.
      final isFromOther = parsed.senderId == null || parsed.senderId != userId;
      final ProvisionalConversationHint? hint = conv == null
          ? ProvisionalConversationHint(
              type: parsed.isGroup ? 'group' : 'direct',
              conversationName: parsed.isGroup
                  ? (parsed.conversationName.trim().isEmpty
                      ? null
                      : parsed.conversationName.trim())
                  : null,
              peerId: isFromOther ? parsed.senderId : null,
              peerName: isFromOther ? parsed.senderName : null,
            )
          : null;

      if (parsed.seq != null && conv != null && parsed.seq! <= conv.clearedSeq) {
        return const _PartitionResult.abort(
          BackgroundPushOutcome.suppressedCleared,
        );
      }

      if (parsed.clientMsgId != null) {
        final existing = await dao.message(parsed.clientMsgId!);
        if (existing != null && _isReadableContent(existing.content)) {
          return const _PartitionResult.abort(
            BackgroundPushOutcome.suppressedDuplicate,
          );
        }
      }

      final isGroup = parsed.isGroup || conv?.type == 'group';
      final title = _resolveTitle(parsed: parsed, conv: conv, isGroup: isGroup);
      final cursor = await dao.effectiveCursor(parsed.conversationId);
      final deviceId = await tokenStore.readDeviceId();

      // Case 1: Fast path — contiguous inline payload (zero network round trip).
      final needsCase1Decrypt = !isGroup &&
          parsed.msgType == 'text' &&
          parsed.content != null &&
          isEncryptedContent(parsed.content!);
      if (parsed.seq != null &&
          parsed.seq! == cursor + 1 &&
          !parsed.contentOmitted &&
          parsed.content != null &&
          parsed.clientMsgId != null &&
          (!needsCase1Decrypt || parsed.senderId != null)) {
        final rawMessage = Message(
          id: parsed.messageId ?? parsed.clientMsgId!,
          conversationId: parsed.conversationId,
          seq: parsed.seq!,
          senderId: parsed.senderId ?? '',
          clientMsgId: parsed.clientMsgId!,
          type: parsed.msgType,
          content: parsed.content!,
          createdAt: parsed.createdAt,
        );

        if (needsCase1Decrypt) {
          final bgLogger = AppLogger();
          final e2ee = E2eeManager(
            tokenStore: tokenStore,
            accountStore: accountStore,
            api: _apiClientFactory(tokenStore, deviceId),
            service: _e2eeServiceFactory(),
            logger: bgLogger,
          );
          final loaded = await e2ee.loadExistingWithoutBootstrap();
          if (!loaded) {
            return _PartitionResult.show(
              title: title,
              displayContent: undecryptableContent,
              isGroup: false,
              outcome: BackgroundPushOutcome.shownFallback,
              fallbackReason: BackgroundFallbackReason.noLocalKeys,
            );
          }

          final plaintext = await e2ee.plaintextFor(
            rawMessage.clientMsgId,
            rawMessage.conversationId,
            rawMessage.content,
            isGroup: false,
            senderId: rawMessage.senderId,
            peerId: conv?.peerId ?? rawMessage.senderId,
            deferSessionPersist: true,
            allowBootstrap: false,
          );

          if (_isReadableContent(plaintext)) {
            final decryptedMsg = Message(
              id: rawMessage.id,
              conversationId: rawMessage.conversationId,
              seq: rawMessage.seq,
              senderId: rawMessage.senderId,
              clientMsgId: rawMessage.clientMsgId,
              type: rawMessage.type,
              content: plaintext,
              createdAt: rawMessage.createdAt,
            );
            // Crash-safe write order: commit SQLite FIRST, Keystore SECOND.
            await dao.upsertServerMessage(
              decryptedMsg,
              status: 'sent',
              ensureConversation: hint,
              incrementUnread: isFromOther,
            );
            try {
              await e2ee.commitSessions();
              await _writeBackgroundE2eeMarker(paths.partitionDir);
            } catch (error) {
              debugPrint(
                'BackgroundPushHandler session commit failed after DB write: $error',
              );
            }
            return _PartitionResult.show(
              title: title,
              displayContent: plaintext,
              isGroup: false,
              outcome: BackgroundPushOutcome.shownDecrypted,
            );
          }

          // Decryption failed: leave DB & ratchet untouched and show fallback.
          return _PartitionResult.show(
            title: title,
            displayContent: undecryptableContent,
            isGroup: false,
            outcome: BackgroundPushOutcome.shownFallback,
            fallbackReason: BackgroundFallbackReason.decryptFailed,
            decryptReason: _extractDecryptReason(bgLogger),
          );
        }

        // Group text, plaintext, or media (no symmetric ratchet involved).
        await dao.upsertServerMessage(
          rawMessage,
          status: 'sent',
          ensureConversation: hint,
          incrementUnread: isFromOther,
        );
        return _PartitionResult.show(
          title: title,
          displayContent: rawMessage.content,
          isGroup: isGroup,
          outcome: BackgroundPushOutcome.shownPlaintext,
        );
      }

      // Case 2: Sequence gap (seq > cursor + 1), oversized payload
      // (`content_omitted: "true"`), or missing senderId on encrypted payload:
      // release `.partition.lock` and fetch via `/sync` before re-acquiring.
      if (parsed.seq != null &&
          (parsed.seq! > cursor + 1 ||
              parsed.contentOmitted ||
              parsed.content == null ||
              (needsCase1Decrypt && parsed.senderId == null))) {
        return _PartitionResult.needsSync(
          _SyncPlan(
            initialCursor: cursor,
            isGroup: isGroup,
            title: title,
            deviceId: deviceId,
            hint: hint,
            isFromOther: isFromOther,
          ),
        );
      }

      // Case 3: Stale seq (<= cursor) that was not found by clientMsgId or
      // legacy data-only payload without seq. Check `(conversationId, seq)`
      // before falling back so an already-readable row suppresses duplicates.
      if (parsed.seq != null) {
        final existingBySeq =
            await dao.messageBySeq(parsed.conversationId, parsed.seq!);
        if (existingBySeq != null && _isReadableContent(existingBySeq.content)) {
          return const _PartitionResult.abort(
            BackgroundPushOutcome.suppressedDuplicate,
          );
        }
      }
      return _PartitionResult.show(
        title: title,
        displayContent: _fallbackDisplayContent(parsed),
        isGroup: isGroup,
        outcome: BackgroundPushOutcome.shownFallback,
        fallbackReason: BackgroundFallbackReason.staleSeq,
      );
    } finally {
      await db.close();
    }
  }

  /// Fetches missing pages over HTTP WITHOUT holding `.partition.lock`.
  Future<_FetchedSyncBatch> _fetchSyncPages({
    required ParsedFcmMessage parsed,
    required _SyncPlan plan,
    required TokenStore tokenStore,
  }) async {
    final api = _apiClientFactory(tokenStore, plan.deviceId);
    final deadline = DateTime.now().add(syncBudget);
    final collected = <Message>[];
    var fetchCursor = plan.initialCursor;
    var maxClearedSeq = 0;
    var latestSeq = 0;
    var hadError = false;
    var hitPageOrBudgetCap = false;

    try {
      for (var pageIndex = 0; pageIndex < maxSyncPages; pageIndex += 1) {
        if (DateTime.now().isAfter(deadline)) {
          hitPageOrBudgetCap = true;
          break;
        }
        final needed = math.max(1, parsed.seq! - fetchCursor);
        final limit = math.min(syncPageLimit, math.max(needed, 10));
        final result = await api.sync(
          parsed.conversationId,
          afterSeq: fetchCursor,
          limit: limit,
        );
        if (result.clearedSeq > maxClearedSeq) {
          maxClearedSeq = result.clearedSeq;
        }
        if (result.latestSeq > latestSeq) {
          latestSeq = result.latestSeq;
        }
        if (result.clearedSeq > fetchCursor) {
          fetchCursor = result.clearedSeq;
        }
        if (parsed.seq! <= maxClearedSeq) {
          break;
        }
        if (result.messages.isEmpty) break;
        collected.addAll(result.messages);
        final lastFetchedSeq = result.messages.last.seq;
        if (lastFetchedSeq <= fetchCursor) break;
        fetchCursor = lastFetchedSeq;
        if (fetchCursor >= result.latestSeq || fetchCursor >= parsed.seq!) {
          break;
        }
        if (pageIndex == maxSyncPages - 1 && fetchCursor < parsed.seq!) {
          hitPageOrBudgetCap = true;
        }
      }
    } catch (error) {
      hadError = true;
      debugPrint('BackgroundPushHandler sync failed: $error');
    }

    return _FetchedSyncBatch(
      api: api,
      messages: collected,
      maxClearedSeq: maxClearedSeq,
      latestSeq: latestSeq,
      hadError: hadError,
      hitPageOrBudgetCap: hitPageOrBudgetCap,
    );
  }

  /// Re-acquires `.partition.lock` briefly to verify continuity, decrypt
  /// fetched messages in ascending `seq` order, commit SQLite BEFORE
  /// persisting ratchet sessions, and return the display payload.
  Future<_PartitionResult> _applySyncedMessagesUnderLock({
    required ParsedFcmMessage parsed,
    required _SyncPlan plan,
    required _FetchedSyncBatch fetched,
    required AccountPaths paths,
    required TokenStore tokenStore,
    required String userId,
    required String activeAccountId,
  }) async {
    final accountStore = AccountStore(tokenStore, activeAccountId);
    final db = AppDatabase.forFile(paths.dbFile);
    try {
      final dbOwner = await db.readMeta(PartitionGuard.ownerUserIdKey);
      final dbPartId = await db.readMeta(PartitionGuard.partitionIdKey);
      final storePartId = await accountStore.readPartitionId();
      if (dbOwner != userId ||
          dbPartId == null ||
          dbPartId.isEmpty ||
          storePartId == null ||
          storePartId.isEmpty ||
          dbPartId != storePartId) {
        return const _PartitionResult.abort(
          BackgroundPushOutcome.droppedIntegrityMismatch,
        );
      }

      final dao = ChatDao(db);
      final conv = await dao.conversation(parsed.conversationId);
      final isGroup = plan.isGroup || conv?.type == 'group';
      final title = _resolveTitle(parsed: parsed, conv: conv, isGroup: isGroup);

      if (fetched.maxClearedSeq > 0) {
        await dao.applyClearedSeq(parsed.conversationId, fetched.maxClearedSeq);
        if (parsed.seq! <= fetched.maxClearedSeq) {
          return const _PartitionResult.abort(
            BackgroundPushOutcome.suppressedCleared,
          );
        }
      }

      if (parsed.clientMsgId != null) {
        final existing = await dao.message(parsed.clientMsgId!);
        if (existing != null && _isReadableContent(existing.content)) {
          return const _PartitionResult.abort(
            BackgroundPushOutcome.suppressedDuplicate,
          );
        }
      }

      var runningCursor = await dao.effectiveCursor(parsed.conversationId);
      if (fetched.maxClearedSeq > runningCursor) {
        runningCursor = fetched.maxClearedSeq;
      }

      final bgLogger = AppLogger();
      E2eeManager? e2ee;
      var keysLoaded = false;
      Message? targetMessage;
      var targetWasEncrypted = false;

      for (final msg in fetched.messages) {
        if (msg.seq <= runningCursor) continue;
        // Enforce strict contiguous seq invariant so the symmetric ratchet
        // never skips past an unreceived message.
        if (msg.seq != runningCursor + 1) {
          return _PartitionResult.show(
            title: title,
            displayContent: _fallbackDisplayContent(parsed),
            isGroup: isGroup,
            outcome: BackgroundPushOutcome.shownFallback,
            fallbackReason: BackgroundFallbackReason.syncDiscontinuous,
          );
        }

        final isTarget = (parsed.clientMsgId != null &&
                msg.clientMsgId == parsed.clientMsgId) ||
            msg.seq == parsed.seq;

        final existing = await dao.message(msg.clientMsgId);
        if (existing != null && _isReadableContent(existing.content)) {
          runningCursor = msg.seq;
          if (isTarget) {
            targetMessage = Message(
              id: msg.id,
              conversationId: msg.conversationId,
              seq: msg.seq,
              senderId: msg.senderId,
              clientMsgId: msg.clientMsgId,
              type: msg.type,
              content: existing.content,
              createdAt: msg.createdAt,
            );
          }
          continue;
        }

        if (!isGroup &&
            msg.type == 'text' &&
            isEncryptedContent(msg.content)) {
          if (msg.senderId == userId) {
            await dao.upsertServerMessage(
              Message(
                id: msg.id,
                conversationId: msg.conversationId,
                seq: msg.seq,
                senderId: msg.senderId,
                clientMsgId: msg.clientMsgId,
                type: msg.type,
                content: undecryptableContent,
                createdAt: msg.createdAt,
              ),
              status: 'sent',
              ensureConversation: plan.hint,
              incrementUnread: false,
            );
            runningCursor = msg.seq;
            continue;
          }

          e2ee ??= E2eeManager(
            tokenStore: tokenStore,
            accountStore: accountStore,
            api: fetched.api,
            service: _e2eeServiceFactory(),
            logger: bgLogger,
          );
          if (!keysLoaded) {
            keysLoaded = await e2ee.loadExistingWithoutBootstrap();
            if (!keysLoaded) {
              return _PartitionResult.show(
                title: title,
                displayContent: undecryptableContent,
                isGroup: false,
                outcome: BackgroundPushOutcome.shownFallback,
                fallbackReason: BackgroundFallbackReason.noLocalKeys,
              );
            }
          }

          final plaintext = await e2ee.plaintextFor(
            msg.clientMsgId,
            msg.conversationId,
            msg.content,
            isGroup: false,
            senderId: msg.senderId,
            peerId: conv?.peerId ?? msg.senderId,
            deferSessionPersist: true,
            allowBootstrap: false,
          );
          if (!_isReadableContent(plaintext)) {
            return _PartitionResult.show(
              title: title,
              displayContent: undecryptableContent,
              isGroup: false,
              outcome: BackgroundPushOutcome.shownFallback,
              fallbackReason: BackgroundFallbackReason.decryptFailed,
              decryptReason: _extractDecryptReason(bgLogger),
            );
          }

          final decryptedMsg = Message(
            id: msg.id,
            conversationId: msg.conversationId,
            seq: msg.seq,
            senderId: msg.senderId,
            clientMsgId: msg.clientMsgId,
            type: msg.type,
            content: plaintext,
            createdAt: msg.createdAt,
          );
          // Crash-safe write order: SQLite FIRST, Keystore SECOND.
          await dao.upsertServerMessage(
            decryptedMsg,
            status: 'sent',
            ensureConversation: plan.hint,
            incrementUnread: plan.isFromOther,
          );
          try {
            await e2ee.commitSessions();
            await _writeBackgroundE2eeMarker(paths.partitionDir);
          } catch (error) {
            debugPrint(
              'BackgroundPushHandler sync session commit failed after DB write: $error',
            );
          }
          runningCursor = msg.seq;
          if (isTarget) {
            targetMessage = decryptedMsg;
            targetWasEncrypted = true;
          }
        } else {
          await dao.upsertServerMessage(
            msg,
            status: 'sent',
            ensureConversation: plan.hint,
            incrementUnread: plan.isFromOther && msg.senderId != userId,
          );
          runningCursor = msg.seq;
          if (isTarget) {
            targetMessage = msg;
          }
        }
      }

      if (targetMessage != null) {
        return _PartitionResult.show(
          title: title,
          displayContent: targetMessage.content,
          isGroup: isGroup,
          outcome: targetWasEncrypted
              ? BackgroundPushOutcome.shownDecrypted
              : BackgroundPushOutcome.shownPlaintext,
        );
      }

      return _PartitionResult.show(
        title: title,
        displayContent: _fallbackDisplayContent(parsed),
        isGroup: isGroup,
        outcome: BackgroundPushOutcome.shownFallback,
        fallbackReason: fetched.hadError
            ? BackgroundFallbackReason.syncFailed
            : (fetched.hitPageOrBudgetCap
                ? BackgroundFallbackReason.syncGapTooLarge
                : BackgroundFallbackReason.syncFailed),
      );
    } finally {
      await db.close();
    }
  }

  Future<void> _showNotification({
    required ParsedFcmMessage parsed,
    required String accountId,
    required bool isGroup,
    required String title,
    required String displayContent,
  }) async {
    final rendered = NotificationPolicy.format(
      isGroup: isGroup,
      conversationName: title,
      senderName: parsed.senderName,
      type: parsed.msgType,
      content: displayContent,
    );
    final sink = await _notificationSinkFactory();
    await sink.showMessageNotification(
      conversationId: parsed.conversationId,
      title: rendered.title,
      body: rendered.body,
      messageId: parsed.messageId ?? parsed.clientMsgId,
      accountId: accountId,
    );
  }

  static bool _isReadableContent(String content) =>
      !isEncryptedContent(content) && content != undecryptableContent;

  static String _resolveTitle({
    required ParsedFcmMessage parsed,
    required LocalConversation? conv,
    required bool isGroup,
  }) {
    if (isGroup) {
      final dbName = conv?.name?.trim();
      if (dbName != null && dbName.isNotEmpty) return dbName;
      final pushName = parsed.conversationName.trim();
      if (pushName.isNotEmpty) return pushName;
      return parsed.senderName ?? 'Group';
    }
    final peerLabel = formatDirectPeerLabel(conv?.peerName, conv?.peerNickname);
    if (peerLabel != null) return peerLabel;
    if (parsed.senderName != null && parsed.senderName!.isNotEmpty) {
      return parsed.senderName!;
    }
    final dbName = conv?.name?.trim();
    if (dbName != null && dbName.isNotEmpty) return dbName;
    return 'New message';
  }

  static String _fallbackTitle(ParsedFcmMessage parsed) {
    if (parsed.isGroup) {
      final name = parsed.conversationName.trim();
      if (name.isNotEmpty) return name;
    }
    return parsed.senderName ?? 'New message';
  }

  static String _fallbackDisplayContent(ParsedFcmMessage parsed) {
    if (parsed.msgType == 'image' || parsed.msgType == 'file') {
      return parsed.content ?? '';
    }
    final content = parsed.content;
    if (content == null || content.isEmpty) {
      return parsed.isGroup ? '' : undecryptableContent;
    }
    if (isEncryptedContent(content)) {
      return undecryptableContent;
    }
    return content;
  }
}

class _SyncPlan {
  const _SyncPlan({
    required this.initialCursor,
    required this.isGroup,
    required this.title,
    required this.deviceId,
    required this.hint,
    required this.isFromOther,
  });

  final int initialCursor;
  final bool isGroup;
  final String title;
  final String? deviceId;
  final ProvisionalConversationHint? hint;
  final bool isFromOther;
}

class _FetchedSyncBatch {
  const _FetchedSyncBatch({
    required this.api,
    required this.messages,
    required this.maxClearedSeq,
    required this.latestSeq,
    required this.hadError,
    required this.hitPageOrBudgetCap,
  });

  final ApiClient api;
  final List<Message> messages;
  final int maxClearedSeq;
  final int latestSeq;
  final bool hadError;
  final bool hitPageOrBudgetCap;
}

class _PartitionResult {
  const _PartitionResult.abort(BackgroundPushOutcome this.abortOutcome)
      : title = '',
        displayContent = '',
        isGroup = false,
        outcome = abortOutcome,
        syncPlan = null,
        fallbackReason = null,
        decryptReason = null;

  const _PartitionResult.needsSync(_SyncPlan this.syncPlan)
      : abortOutcome = null,
        title = '',
        displayContent = '',
        isGroup = false,
        outcome = BackgroundPushOutcome.shownFallback,
        fallbackReason = null,
        decryptReason = null;

  const _PartitionResult.show({
    required this.title,
    required this.displayContent,
    required this.isGroup,
    required this.outcome,
    this.fallbackReason,
    this.decryptReason,
  })  : abortOutcome = null,
        syncPlan = null;

  final BackgroundPushOutcome? abortOutcome;
  final _SyncPlan? syncPlan;
  final String title;
  final String displayContent;
  final bool isGroup;
  final BackgroundPushOutcome outcome;
  final BackgroundFallbackReason? fallbackReason;
  final String? decryptReason;
}
