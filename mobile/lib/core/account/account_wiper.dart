import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../database/chat_dao.dart';
import '../logging/app_logger.dart';
import '../media/account_media_cache.dart';
import '../network/api_client.dart';
import '../storage/app_dirs.dart';
import '../storage/token_store.dart';
import 'account_paths.dart';
import 'account_registry.dart';
import 'account_scope.dart';
import 'account_store.dart';

/// Executes Level 1 (clear chat history, keep keys/login) and Level 2 (delete
/// whole account partition + keys + registry entry) wipes, plus crash-resumable
/// janitor cleanup on startup (§2.5, §3.2, §3.5).
class AccountWiper {
  AccountWiper({
    required this.tokenStore,
    required this.dirs,
    required this.registry,
    required this.dbGate,
    this.logger,
  });

  final TokenStore tokenStore;
  final AppDirs dirs;
  final AccountRegistry registry;
  final DbGate dbGate;
  final AppLogger? logger;

  /// L1 — Clear a single conversation's history while staying signed in and
  /// keeping E2EE keys/sessions intact.
  ///
  /// Local rows are cleared immediately and `cleared_seq` is set to at least
  /// the local cursor. If the server request fails (e.g. offline), the clear is
  /// queued in `acct.<id>.pending_server_clear` and retried before the next
  /// `syncAll`.
  Future<void> clearConversation({
    required String accountId,
    required String conversationId,
    required ChatDao dao,
    required ApiClient api,
  }) async {
    final store = AccountStore(tokenStore, accountId);
    final localSeq = await dao.effectiveCursor(conversationId);
    await dao.clearConversationRows(conversationId, clearedSeq: localSeq);

    try {
      final serverCleared = await api.clearConversation(conversationId);
      await dao.applyClearedSeq(conversationId, serverCleared);
    } catch (error) {
      debugPrint('AccountWiper.clearConversation offline, queuing retry: $error');
      await store.addPendingConversationClear(conversationId);
    }
  }

  /// L1 — Clear all chat history (messages, outbox, previews, unread, drafts)
  /// and empty the account's media cache while keeping login + E2EE keys.
  Future<void> clearAllChats({
    required String accountId,
    required ChatDao dao,
    required ApiClient api,
    AccountMediaCache? mediaCache,
  }) async {
    final store = AccountStore(tokenStore, accountId);
    await dao.clearAllHistoryKeepWatermarks();
    if (mediaCache != null) {
      await mediaCache.clearAccountCache();
    } else {
      final paths = await AccountPaths.resolve(accountId, dirs);
      await _deleteDirQuietly(paths.mediaCacheDir);
      evictMemoryImageCache();
    }

    try {
      final cleared = await api.clearAllHistory();
      for (final entry in cleared.entries) {
        await dao.applyClearedSeq(entry.key, entry.value);
      }
      await store.clearPendingServerClear();
    } catch (error) {
      debugPrint('AccountWiper.clearAllChats offline, queuing retry: $error');
      await store.setPendingClearAll();
    }
  }

  /// L2 — Delete an entire account partition (DB + WAL/SHM, media cache, temp
  /// files, `acct.<id>.*` keys/sessions, registry entry).
  ///
  /// Writes a `wipe_pending.<accountId>` marker first so a crash mid-delete is
  /// completed by [resumePendingWipes] on the next startup.
  ///
  /// When [notifyServer] is true (e.g. "Sign out & remove my data"), attempts
  /// `POST /users/me/history/clear` best-effort before deleting local state; if
  /// offline, sets a `pending_l2_clear.<accountId>` flag that survives deletion
  /// so the next login of this user advances server watermarks before syncing.
  Future<void> wipeAccountPartition({
    required String accountId,
    AppDatabase? openDb,
    AccountMediaCache? mediaCache,
    ApiClient? api,
    bool notifyServer = false,
  }) async {
    if (notifyServer && api != null) {
      try {
        await api.clearAllHistory().timeout(const Duration(seconds: 3));
        await registry.setPendingL2ServerClear(accountId, false);
      } catch (error) {
        debugPrint('AccountWiper L2 server clear offline, flagging for next login: $error');
        await registry.setPendingL2ServerClear(accountId, true);
      }
    }

    // Mark wipe pending first so a crash cannot leave half-deleted files.
    await registry.markWipePending(accountId);
    await _executePartitionDelete(
      accountId: accountId,
      openDb: openDb,
      mediaCache: mediaCache,
    );
  }

  /// Finishes any L2 wipes that were interrupted by a crash or OS kill.
  Future<void> resumePendingWipes() async {
    final pending = await registry.pendingWipes();
    for (final accountId in pending) {
      logger?.info('wiper', 'resuming interrupted wipe', meta: {'account_id': accountId});
      await _executePartitionDelete(accountId: accountId);
    }
  }

  /// Replays any queued offline L1/L2 server clears before `syncAll`.
  Future<void> flushPendingServerClears({
    required String accountId,
    required ApiClient api,
    required ChatDao dao,
  }) async {
    final store = AccountStore(tokenStore, accountId);
    final pendingL2 = await registry.hasPendingL2ServerClear(accountId);
    final pendingL1 = await store.readPendingServerClear();

    if (pendingL2 || pendingL1.clearAll) {
      try {
        final cleared = await api.clearAllHistory();
        for (final entry in cleared.entries) {
          await dao.applyClearedSeq(entry.key, entry.value);
        }
        await registry.setPendingL2ServerClear(accountId, false);
        await store.clearPendingServerClear();
      } catch (error) {
        debugPrint('AccountWiper pending clear-all retry failed: $error');
      }
      return;
    }

    if (pendingL1.conversationIds.isEmpty) return;

    final remaining = <String>[];
    for (final convId in pendingL1.conversationIds) {
      try {
        final seq = await api.clearConversation(convId);
        await dao.applyClearedSeq(convId, seq);
      } catch (_) {
        remaining.add(convId);
      }
    }
    await store.writePendingServerClear(
      PendingServerClear(conversationIds: remaining),
    );
  }

  Future<void> _executePartitionDelete({
    required String accountId,
    AppDatabase? openDb,
    AccountMediaCache? mediaCache,
  }) async {
    final paths = await AccountPaths.resolve(accountId, dirs);
    final store = AccountStore(tokenStore, accountId);

    // 1. Close DB and remove SQLite + sidecar files under DbGate lock.
    await dbGate.run(paths.dbFile.path, () async {
      if (openDb != null && !openDb.isClosed) {
        try {
          await openDb.close();
        } catch (_) {
          // Best effort.
        }
      }
      for (final file in paths.dbFiles) {
        await _deleteFileQuietly(file);
      }
      await _deleteDirQuietly(paths.partitionDir);
    });

    // 2. Empty media cache & remove account cache dir (media + tmp).
    if (mediaCache != null) {
      await mediaCache.clearAccountCache();
    } else {
      evictMemoryImageCache();
    }
    await _deleteDirQuietly(paths.cacheDir);

    // 3. Delete all acct.<id>.* secure-storage keys and remove registry entry.
    await store.deleteAll();
    await registry.remove(accountId);

    // 4. Clear pending wipe marker only once everything is gone.
    await registry.clearWipePending(accountId);
  }

  Future<void> _deleteFileQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _deleteDirQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort.
    }
  }
}
