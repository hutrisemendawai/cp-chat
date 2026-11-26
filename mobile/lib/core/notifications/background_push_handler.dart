import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show IsolateNameServer;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

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
    this.mainIsolateHandoffTimeout = const Duration(seconds: 5),
    this.lockTimeout = const Duration(seconds: 5),
    this.maxSyncPages = 2,
    this.syncPageLimit = 50,
  })  : _tokenStoreFactory = tokenStoreFactory ?? TokenStore.forBackground,
        _appDirsFactory = appDirsFactory ?? AppDirs.new,
        _apiClientFactory = apiClientFactory ?? _defaultApiClient,
        _notificationSinkFactory =
            notificationSinkFactory ?? _defaultNotificationSink,
        _e2eeServiceFactory = e2eeServiceFactory ?? E2eeService.new,
        _portLookup = portLookup ?? IsolateNameServer.lookupPortByName;

  static final BackgroundPushHandler shared = BackgroundPushHandler();

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

  /// In-isolate FIFO queue so rapid back-to-back FCM pushes execute strictly
  /// one at a time.
  Future<void> _queue = Future<void>.value();

  static ApiClient _defaultApiClient(TokenStore store, String? deviceId) =>
      ApiClient(
        store,
        deviceId: deviceId,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
      );

  static Future<MessageNotificationSink> _defaultNotificationSink() async {
    final service = LocalNotificationService();
    await service.initialize(checkLaunchDetails: false);
    return service;
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
    if (layout != LegacyMigration.layoutVersion) {
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }

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
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }

    // 6. Acquire exclusive cross-isolate partition lock, verify integrity,
    //    decrypt & persist, then close DB and release lock before notifying.
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
      await _showNotification(
        parsed: parsed,
        accountId: activeAccountId,
        isGroup: parsed.isGroup,
        title: _fallbackTitle(parsed),
        displayContent: _fallbackDisplayContent(parsed),
      );
      return BackgroundPushOutcome.shownFallback;
    }

    if (result.abortOutcome != null) {
      return result.abortOutcome!;
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
      if (parsed.seq != null &&
          parsed.seq! == cursor + 1 &&
          !parsed.contentOmitted &&
          parsed.content != null &&
          parsed.clientMsgId != null) {
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

        if (!isGroup &&
            parsed.msgType == 'text' &&
            isEncryptedContent(parsed.content!)) {
          final e2ee = E2eeManager(
            tokenStore: tokenStore,
            accountStore: accountStore,
            api: _apiClientFactory(tokenStore, deviceId),
            service: _e2eeServiceFactory(),
          );
          final loaded = await e2ee.loadExistingWithoutBootstrap();
          if (!loaded) {
            return _PartitionResult.show(
              title: title,
              displayContent: undecryptableContent,
              isGroup: false,
              outcome: BackgroundPushOutcome.shownFallback,
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
            await dao.upsertServerMessage(decryptedMsg, status: 'sent');
            try {
              await e2ee.commitSessions();
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
          );
        }

        // Group text, plaintext, or media (no symmetric ratchet involved).
        await dao.upsertServerMessage(rawMessage, status: 'sent');
        return _PartitionResult.show(
          title: title,
          displayContent: rawMessage.content,
          isGroup: isGroup,
          outcome: BackgroundPushOutcome.shownPlaintext,
        );
      }

      // Case 2: Sequence gap (seq > cursor + 1) or oversized payload
      // (`content_omitted: "true"`): fetch missing range via authenticated
      // `/sync` and decrypt/persist strictly in ascending seq order.
      if (parsed.seq != null &&
          (parsed.seq! > cursor + 1 ||
              parsed.contentOmitted ||
              parsed.content == null)) {
        return await _syncGapOrOversized(
          parsed: parsed,
          conv: conv,
          dao: dao,
          tokenStore: tokenStore,
          accountStore: accountStore,
          deviceId: deviceId,
          isGroup: isGroup,
          title: title,
          initialCursor: cursor,
        );
      }

      // Case 3: Stale seq (<= cursor) that was not found by clientMsgId or
      // legacy data-only payload without seq: show safe fallback without
      // mutating the ratchet.
      return _PartitionResult.show(
        title: title,
        displayContent: _fallbackDisplayContent(parsed),
        isGroup: isGroup,
        outcome: BackgroundPushOutcome.shownFallback,
      );
    } finally {
      await db.close();
    }
  }

  Future<_PartitionResult> _syncGapOrOversized({
    required ParsedFcmMessage parsed,
    required LocalConversation? conv,
    required ChatDao dao,
    required TokenStore tokenStore,
    required AccountStore accountStore,
    required String? deviceId,
    required bool isGroup,
    required String title,
    required int initialCursor,
  }) async {
    final api = _apiClientFactory(tokenStore, deviceId);
    E2eeManager? e2ee;
    var keysLoaded = false;
    var runningCursor = initialCursor;
    Message? targetMessage;
    var targetWasEncrypted = false;

    try {
      for (var pageIndex = 0; pageIndex < maxSyncPages; pageIndex += 1) {
        final needed = math.max(1, parsed.seq! - runningCursor);
        final limit = math.min(syncPageLimit, math.max(needed, 10));
        final result = await api.sync(
          parsed.conversationId,
          afterSeq: runningCursor,
          limit: limit,
        );

        if (result.clearedSeq > 0) {
          await dao.applyClearedSeq(parsed.conversationId, result.clearedSeq);
          if (parsed.seq! <= result.clearedSeq) {
            return const _PartitionResult.abort(
              BackgroundPushOutcome.suppressedCleared,
            );
          }
          if (result.clearedSeq > runningCursor) {
            runningCursor = result.clearedSeq;
          }
        }

        if (result.messages.isEmpty) break;

        for (final msg in result.messages) {
          if (msg.seq <= runningCursor) continue;
          // Enforce strict contiguous seq invariant so the symmetric ratchet
          // never skips past an unreceived message.
          if (msg.seq != runningCursor + 1) {
            return _PartitionResult.show(
              title: title,
              displayContent: _fallbackDisplayContent(parsed),
              isGroup: isGroup,
              outcome: BackgroundPushOutcome.shownFallback,
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
            e2ee ??= E2eeManager(
              tokenStore: tokenStore,
              accountStore: accountStore,
              api: api,
              service: _e2eeServiceFactory(),
            );
            if (!keysLoaded) {
              keysLoaded = await e2ee.loadExistingWithoutBootstrap();
              if (!keysLoaded) {
                return _PartitionResult.show(
                  title: title,
                  displayContent: undecryptableContent,
                  isGroup: false,
                  outcome: BackgroundPushOutcome.shownFallback,
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
              // Abort before persisting or advancing ratchet.
              return _PartitionResult.show(
                title: title,
                displayContent: undecryptableContent,
                isGroup: false,
                outcome: BackgroundPushOutcome.shownFallback,
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
            await dao.upsertServerMessage(decryptedMsg, status: 'sent');
            try {
              await e2ee.commitSessions();
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
            await dao.upsertServerMessage(msg, status: 'sent');
            runningCursor = msg.seq;
            if (isTarget) {
              targetMessage = msg;
            }
          }
        }

        if (runningCursor >= result.latestSeq || runningCursor >= parsed.seq!) {
          break;
        }
      }
    } catch (error) {
      debugPrint('BackgroundPushHandler sync failed: $error');
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
    );
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

class _PartitionResult {
  const _PartitionResult.abort(BackgroundPushOutcome this.abortOutcome)
      : title = '',
        displayContent = '',
        isGroup = false,
        outcome = abortOutcome;

  const _PartitionResult.show({
    required this.title,
    required this.displayContent,
    required this.isGroup,
    required this.outcome,
  }) : abortOutcome = null;

  final BackgroundPushOutcome? abortOutcome;
  final String title;
  final String displayContent;
  final bool isGroup;
  final BackgroundPushOutcome outcome;
}
