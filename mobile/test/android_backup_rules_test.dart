import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';

const _requiredBackupDomains = <String>{
  'root',
  'file',
  'database',
  'sharedpref',
  'external',
  'device_root',
  'device_file',
  'device_database',
};

/// Secure storage stub that always throws a [PlatformException], simulating a
/// lost Keystore key or corrupt restored preferences.
class _FailingSecureStorage extends FlutterSecureStorage {
  const _FailingSecureStorage();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(
      code: 'Exception encountered',
      message: 'BadPaddingException: Keystore key invalidated',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android backup & extraction rules', () {
    test('AndroidManifest disables backup and wires both backup XML configs', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);

      final doc = XmlDocument.parse(manifestFile.readAsStringSync());
      final app = doc.findAllElements('application').single;

      expect(app.getAttribute('android:allowBackup'), 'false');
      expect(app.getAttribute('android:fullBackupContent'), '@xml/backup_rules');
      expect(app.getAttribute('android:dataExtractionRules'), '@xml/data_extraction_rules');
    });

    test('data_extraction_rules.xml excludes every domain in cloud-backup and device-transfer', () {
      final file = File('android/app/src/main/res/xml/data_extraction_rules.xml');
      expect(file.existsSync(), isTrue);

      final raw = file.readAsStringSync();
      // Stale comment claiming history is silently re-synced must be gone.
      expect(raw, isNot(contains('it is re-synced from the server')));

      final doc = XmlDocument.parse(raw);

      for (final sectionName in ['cloud-backup', 'device-transfer']) {
        final section = doc.findAllElements(sectionName).single;
        final excludedDomains = section
            .findElements('exclude')
            .where((e) => e.getAttribute('path') == '.')
            .map((e) => e.getAttribute('domain'))
            .whereType<String>()
            .toSet();
        expect(
          excludedDomains,
          containsAll(_requiredBackupDomains),
          reason: '<$sectionName> must exclude all backup domains',
        );
      }
    });

    test('backup_rules.xml excludes every domain for Android <= 11', () {
      final file = File('android/app/src/main/res/xml/backup_rules.xml');
      expect(file.existsSync(), isTrue);

      final doc = XmlDocument.parse(file.readAsStringSync());
      final root = doc.findAllElements('full-backup-content').single;
      final excludedDomains = root
          .findElements('exclude')
          .where((e) => e.getAttribute('path') == '.')
          .map((e) => e.getAttribute('domain'))
          .whereType<String>()
          .toSet();
      expect(excludedDomains, containsAll(_requiredBackupDomains));
    });
  });

  group('AppDirs', () {
    const channel = MethodChannel('cpchat/storage');

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns a path under no_backup on Android via cpchat/storage channel', () async {
      final temp = await Directory.systemTemp.createTemp('cpchat_android_nb_');
      addTearDown(() => temp.delete(recursive: true));
      final androidNoBackup = '${temp.path}/no_backup';

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNoBackupFilesDir') return androidNoBackup;
        return null;
      });

      final dir = await AppDirs.noBackup();
      expect(dir.path, contains('no_backup'));
      expect(dir.path, androidNoBackup);
      expect(await dir.exists(), isTrue);
    });

    test('falls back to a temp path in tests when no channel is registered', () async {
      final dir = await AppDirs.noBackup();
      expect(dir.path, contains('no_backup'));
      expect(await dir.exists(), isTrue);
    });
  });

  group('TokenStore error handling', () {
    test('PlatformException during read makes hydrateAuthState return unauthenticated without throwing', () async {
      final errors = <String>[];
      final store = TokenStore(
        const _FailingSecureStorage(),
        (op, key, error) => errors.add('$op:$key'),
      );

      final state = await hydrateAuthState(store);
      expect(state.isUnauthenticated, isTrue);
      expect(errors, isNotEmpty);
    });
  });
}
