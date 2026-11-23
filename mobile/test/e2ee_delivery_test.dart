import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/crypto/e2ee_manager.dart';
import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/storage/token_store.dart';

import 'support/factories.dart';

class _MemoryStore extends TokenStore {
  _MemoryStore({this.userId});

  final String? userId;
  String? keyBlob;
  String? sessionBlob;

  @override
  Future<String?> readUserId() async => userId;
  @override
  Future<String?> readE2eeKeys() async => keyBlob;
  @override
  Future<void> writeE2eeKeys(String json) async => keyBlob = json;
  @override
  Future<String?> readE2eeSessions() async => sessionBlob;
  @override
  Future<void> writeE2eeSessions(String json) async => sessionBlob = json;
}

class _FakeApi extends ApiClient {
  _FakeApi(super.tokenStore, {this.bundles = const {}});

  final Map<String, RemotePrekeyBundle> bundles;

  @override
  Future<int> publishKeys(PublicKeyBundle bundle) async => bundle.prekeys.length;
  @override
  Future<int> addPrekeys(List<PublicPrekey> prekeys) async => prekeys.length;
  @override
  Future<int> myPrekeyCount() async => 100;
  @override
  Future<RemotePrekeyBundle> prekeyBundle(String userId) async => bundles[userId]!;
}

RemotePrekeyBundle _bundleFor(PublicKeyBundle public) {
  final prekey = public.prekeys.first;
  return RemotePrekeyBundle(
    userId: 'bob',
    identityKey: public.identityKey,
    signingKey: public.signingKey,
    signedPrekeyId: public.signedPrekeyId,
    signedPrekey: public.signedPrekey,
    signedPrekeySignature: public.signedPrekeySignature,
    oneTimePrekeyId: prekey.keyId,
    oneTimePrekey: prekey.publicKey,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late ChatDao dao;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ChatDao(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('a live frame followed by a REST sync decrypts the message only once', () async {
    final bobService = E2eeService(prekeyCount: 3);
    final bobKeys = await bobService.generateKeyMaterial(startPrekeyId: 100);
    final bobStore = _MemoryStore(userId: 'bob')
      ..keyBlob = await bobService.exportKeyMaterial(bobKeys);

    final bobPublic = await bobService.buildPublicBundle(bobKeys);

    final aliceStore = _MemoryStore(userId: 'alice');
    final alice = E2eeManager(
      tokenStore: aliceStore,
      api: _FakeApi(aliceStore, bundles: {'bob': _bundleFor(bobPublic)}),
    );
    await alice.bootstrap();

    final content = (await alice.encryptForConversation(
      conversationId: 'conv-1',
      plaintext: 'only decrypted once',
      isGroup: false,
      peerId: 'bob',
    ))!;

    await dao.upsertConversations([conversation('conv-1', selfId: 'bob')], selfId: 'bob');

    final manager = E2eeManager(
      tokenStore: bobStore,
      api: _FakeApi(bobStore),
      service: E2eeService(prekeyCount: 3),
    );
    await manager.bootstrap();

    var decryptCalls = 0;
    final socket = ChatSocket(
      dao,
      _FakeApi(bobStore),
      bobStore,
      decrypt: (conversationId, clientMsgId, senderId, body, {required isGroup}) {
        decryptCalls += 1;
        return manager.plaintextFor(
          clientMsgId,
          conversationId,
          body,
          isGroup: isGroup,
          senderId: senderId,
        );
      },
    );

    final frame = message(
      'c1',
      conversationId: 'conv-1',
      seq: 1,
      senderId: 'alice',
      content: content,
    );

    // The live socket path stores the plaintext...
    await socket.storeServerMessages([frame]);
    // ...and a REST sync replays the same row.
    await socket.storeServerMessages([frame]);

    final rows = await dao.watchMessages('conv-1').first;
    expect(rows.single.content, 'only decrypted once');
    expect(
      decryptCalls,
      1,
      reason: 'the second delivery must reuse the stored plaintext instead of '
          'advancing the ratchet again',
    );

    await socket.dispose();
  });
}
