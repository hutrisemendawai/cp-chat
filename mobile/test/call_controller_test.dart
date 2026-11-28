import 'dart:async';
import 'dart:io';

import 'package:cp_chat/core/models/call_models.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/notifications/background_push_handler.dart';
import 'package:cp_chat/core/notifications/local_notification_service.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/calls/call_controller.dart';
import 'package:cp_chat/features/calls/call_permissions.dart';
import 'package:cp_chat/features/calls/livekit_media_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);
}

class _TestAuth extends AuthController {
  @override
  AuthState build() => const AuthState.unauthenticated();

  void signIn(String userId) {
    state = AuthState.authenticated(
      AuthSession(
        user: User(id: userId, name: 'User $userId'),
        accessToken: 'tok-$userId',
        refreshToken: 'ref-$userId',
        expiresIn: 900,
      ),
    );
  }
}

class _FakeMediaEngine implements CallMediaEngine {
  final _snapshots = StreamController<CallMediaSnapshot>.broadcast();
  final _events = StreamController<CallMediaConnectionEvent>.broadcast();
  CallMediaSnapshot _current = const CallMediaSnapshot();

  int connectCalls = 0;
  int disposeCalls = 0;
  bool micEnabled = true;
  bool cameraEnabled = false;
  Set<String> lastSubscribed = const {};

  @override
  Stream<CallMediaSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<CallMediaConnectionEvent> get connectionEvents => _events.stream;

  @override
  CallMediaSnapshot get currentSnapshot => _current;

  @override
  Future<void> connect({
    required String url,
    required String token,
    required bool enableVideo,
  }) async {
    connectCalls += 1;
    cameraEnabled = enableVideo;
    micEnabled = true;
    _events.add(CallMediaConnectionEvent.connected);
  }

  @override
  Future<void> disconnectAndDispose() async {
    disposeCalls += 1;
  }

  @override
  Future<List<AudioRoute>> refreshAudioRoutes() async =>
      const [AudioRoute.earpiece, AudioRoute.speaker];

  @override
  Future<void> setAudioRoute(AudioRoute route) async {
    _current = CallMediaSnapshot(audioRoute: route);
    _snapshots.add(_current);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraEnabled = enabled;
  }

  @override
  Future<void> setMicEnabled(bool enabled) async {
    micEnabled = enabled;
  }

  @override
  void setSubscribedVideoParticipants(Set<String> visibleUserIds) {
    lastSubscribed = visibleUserIds;
  }

  @override
  Future<void> switchCamera() async {}

  void emitEvent(CallMediaConnectionEvent event) => _events.add(event);
}

class _FakeCallApi extends ApiClient {
  _FakeCallApi(super.store);

  final List<String> rejectedCalls = [];
  final List<String> cancelledCalls = [];
  final List<String> leftCalls = [];
  bool acceptThrowsEnded = false;

  @override
  Future<CallJoinGrant> startCall(
    String conversationId, {
    required CallMediaType mediaType,
  }) async {
    final isGroup = conversationId.startsWith('group-');
    return CallJoinGrant(
      call: ActiveCallSummary(
        callId: 'call-$conversationId',
        conversationId: conversationId,
        roomName: 'call_call-$conversationId',
        type: isGroup ? CallType.group : CallType.oneOnOne,
        mediaType: mediaType,
        initiatedBy: 'user-a',
        status: isGroup ? 'active' : 'ringing',
        participantCount: 1,
        participantIds: const ['user-a'],
        startedAt: DateTime.now().toUtc(),
      ),
      livekitUrl: 'wss://livekit.test.local',
      token: 'lk-jwt-token',
      expiresIn: 600,
    );
  }

  @override
  Future<CallJoinGrant> acceptCall(String callId) async {
    if (acceptThrowsEnded) {
      throw ApiException(
        'call_already_ended',
        'Call is no longer ringing',
        statusCode: 409,
      );
    }
    return CallJoinGrant(
      call: ActiveCallSummary(
        callId: callId,
        conversationId: 'conv-1',
        roomName: 'call_$callId',
        type: CallType.oneOnOne,
        mediaType: CallMediaType.voice,
        initiatedBy: 'user-b',
        status: 'active',
        participantCount: 2,
        participantIds: const ['user-b', 'user-a'],
        startedAt: DateTime.now().toUtc(),
      ),
      livekitUrl: 'wss://livekit.test.local',
      token: 'lk-accept-token',
      expiresIn: 600,
    );
  }

  @override
  Future<void> rejectCall(String callId, {String reason = 'declined'}) async {
    rejectedCalls.add('$callId:$reason');
  }

  @override
  Future<void> cancelCall(String callId) async {
    cancelledCalls.add(callId);
  }

  @override
  Future<void> leaveCall(String callId) async {
    leftCalls.add(callId);
  }
}

class _FakePermissionService extends CallPermissionService {
  const _FakePermissionService();

  @override
  Future<CallPermissionResult> ensureForVoice() async =>
      const CallPermissionResult(microphone: CallPermissionOutcome.granted);

  @override
  Future<CallPermissionResult> ensureForVideo() async =>
      const CallPermissionResult(
        microphone: CallPermissionOutcome.granted,
        camera: CallPermissionOutcome.granted,
      );

  @override
  Future<CallPermissionOutcome> ensureCameraForUpgrade() async =>
      CallPermissionOutcome.granted;

  @override
  Future<CallPermissionOutcome> ensureBluetoothConnect() async =>
      CallPermissionOutcome.granted;
}

class _FakeNotificationSink implements MessageNotificationSink {
  final List<Map<String, String?>> shown = [];

  @override
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
    String? accountId,
  }) async {
    shown.add({
      'conversationId': conversationId,
      'title': title,
      'body': body,
      'messageId': messageId,
      'accountId': accountId,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallController state machine', () {
    late Directory root;
    late _MapTokenStore store;
    late _FakeMediaEngine media;
    late _FakeCallApi api;
    late ProviderContainer container;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cpchat_call_test_');
      final dirs = AppDirs.forTesting(root);
      await dirs.initialize();
      store = _MapTokenStore();
      media = _FakeMediaEngine();
      api = _FakeCallApi(store);

      container = ProviderContainer(
        overrides: [
          appDirsProvider.overrideWithValue(dirs),
          tokenStoreProvider.overrideWithValue(store),
          authControllerProvider.overrideWith(_TestAuth.new),
          apiClientProvider.overrideWithValue(api),
          livekitMediaServiceProvider.overrideWithValue(media),
          callPermissionServiceProvider.overrideWithValue(
            const _FakePermissionService(),
          ),
        ],
      );
      (container.read(authControllerProvider.notifier) as _TestAuth)
          .signIn('user-a');
    });

    tearDown(() async {
      container.dispose();
      await root.delete(recursive: true);
    });

    test('1:1 outgoing call -> accepted -> mute/camera toggle -> hangup cleans up', () async {
      final ctrl = container.read(callControllerProvider.notifier);

      final result = await ctrl.startCall(
        conversationId: 'conv-1',
        mediaType: CallMediaType.voice,
        isGroup: false,
        title: 'Bob',
      );
      expect(result, CallStartFeedback.started);
      expect(container.read(callControllerProvider).status, CallStatus.calling);
      expect(media.connectCalls, 1);

      await ctrl.handleWsCallEvent({
        'type': 'call_accepted',
        'call_id': 'call-conv-1',
        'conversation_id': 'conv-1',
        'accepted_by': 'user-b',
      });
      expect(container.read(callControllerProvider).status, CallStatus.connected);

      await ctrl.toggleMute();
      expect(container.read(callControllerProvider).localAudioMuted, isTrue);
      expect(media.micEnabled, isFalse);

      final camOutcome = await ctrl.toggleCamera();
      expect(camOutcome, CallPermissionOutcome.granted);
      expect(container.read(callControllerProvider).localVideoEnabled, isTrue);
      expect(media.cameraEnabled, isTrue);

      await ctrl.hangUp();
      expect(api.leftCalls, contains('call-conv-1'));
      expect(container.read(callControllerProvider).status, CallStatus.ended);
      expect(media.disposeCalls, greaterThanOrEqualTo(1));
    });

    test('incoming 1:1 call auto-rejects busy when already in another call', () async {
      final ctrl = container.read(callControllerProvider.notifier);
      await ctrl.startCall(
        conversationId: 'conv-1',
        mediaType: CallMediaType.voice,
        isGroup: false,
        title: 'Bob',
      );

      await ctrl.handleWsCallEvent({
        'type': 'call_incoming',
        'call_id': 'call-other',
        'conversation_id': 'conv-2',
        'call_type': '1on1',
        'media_type': 'video',
        'room_name': 'call_call-other',
        'caller': {'id': 'user-c', 'name': 'Carol'},
        'expires_at': DateTime.now().toUtc().add(const Duration(seconds: 40)).toIso8601String(),
      });
      await Future<void>.delayed(Duration.zero);

      expect(api.rejectedCalls, contains('call-other:busy'));
      expect(container.read(callControllerProvider).currentCallId, 'call-conv-1');
    });

    test('cancel-vs-accept race transitions cleanly to ended without crashing', () async {
      final ctrl = container.read(callControllerProvider.notifier);
      await ctrl.handleWsCallEvent({
        'type': 'call_incoming',
        'call_id': 'call-race',
        'conversation_id': 'conv-1',
        'call_type': '1on1',
        'media_type': 'voice',
        'room_name': 'call_call-race',
        'caller': {'id': 'user-b', 'name': 'Bob'},
        'expires_at': DateTime.now().toUtc().add(const Duration(seconds: 40)).toIso8601String(),
      });
      expect(container.read(callControllerProvider).status, CallStatus.ringing);

      api.acceptThrowsEnded = true;
      final res = await ctrl.acceptIncoming();
      expect(res, CallStartFeedback.failed);
      expect(container.read(callControllerProvider).status, CallStatus.ended);
      expect(container.read(callControllerProvider).endReason, 'Call already ended');
    });

    test('group call WS events keep activeGroupCallsProvider synchronized', () async {
      final ctrl = container.read(callControllerProvider.notifier);

      await ctrl.handleWsCallEvent({
        'type': 'group_call_started',
        'call_id': 'gcall-1',
        'conversation_id': 'group-1',
        'conversation_name': 'Engineering',
        'media_type': 'video',
        'started_by': {'id': 'user-b', 'name': 'Bob'},
        'participant_count': 1,
        'participant_ids': ['user-b'],
      });
      expect(
        container.read(activeGroupCallsProvider)['group-1']?.participantCount,
        1,
      );

      await ctrl.handleWsCallEvent({
        'type': 'group_call_updated',
        'call_id': 'gcall-1',
        'conversation_id': 'group-1',
        'participant_count': 3,
        'participant_ids': ['user-b', 'user-c', 'user-d'],
      });
      expect(
        container.read(activeGroupCallsProvider)['group-1']?.participantCount,
        3,
      );

      await ctrl.handleWsCallEvent({
        'type': 'group_call_ended',
        'call_id': 'gcall-1',
        'conversation_id': 'group-1',
        'reason': 'room_finished',
      });
      expect(container.read(activeGroupCallsProvider)['group-1'], isNull);
    });
  });

  group('BackgroundPushHandler call fast-path', () {
    test('shows call_invite without opening SQLite and rejects expired/foreign invites', () async {
      final tokenStore = _MapTokenStore();
      await tokenStore.saveSession(
        accessToken: 'acc',
        refreshToken: 'ref',
        userId: 'user-a',
      );
      final sink = _FakeNotificationSink();

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => tokenStore,
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      // Valid non-expired call_invite for active account.
      final futureMs =
          DateTime.now().toUtc().add(const Duration(seconds: 30)).millisecondsSinceEpoch;
      final ok = await handler.handleData({
        'push_schema': '2',
        'type': 'call_invite',
        'call_id': 'c-1',
        'conversation_id': 'conv-1',
        'call_type': '1on1',
        'media_type': 'video',
        'caller_id': 'user-b',
        'caller_name': 'Bob',
        'recipient_user_id': 'user-a',
        'expires_at': '$futureMs',
      });
      expect(ok, BackgroundPushOutcome.shownCallInvite);
      expect(sink.shown, hasLength(1));

      // Expired call_invite is dropped.
      final pastMs =
          DateTime.now().toUtc().subtract(const Duration(seconds: 5)).millisecondsSinceEpoch;
      final expired = await handler.handleData({
        'push_schema': '2',
        'type': 'call_invite',
        'call_id': 'c-2',
        'conversation_id': 'conv-1',
        'recipient_user_id': 'user-a',
        'expires_at': '$pastMs',
      });
      expect(expired, BackgroundPushOutcome.droppedExpiredCall);

      // Foreign recipient is dropped for account isolation.
      final foreign = await handler.handleData({
        'push_schema': '2',
        'type': 'call_invite',
        'call_id': 'c-3',
        'conversation_id': 'conv-1',
        'recipient_user_id': 'user-other',
        'expires_at': '$futureMs',
      });
      expect(foreign, BackgroundPushOutcome.droppedAccountMismatch);

      // Cancellation push returns cancelledCallNotification.
      final cancel = await handler.handleData({
        'push_schema': '2',
        'type': 'call_cancel',
        'call_id': 'c-1',
        'conversation_id': 'conv-1',
        'recipient_user_id': 'user-a',
      });
      expect(cancel, BackgroundPushOutcome.cancelledCallNotification);
    });
  });
}
