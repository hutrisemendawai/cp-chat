import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/logging/app_logger.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/storage/token_store.dart';

/// A token store with no platform dependency, so the interceptor chain can run
/// inside a unit test.
class _EmptyTokenStore extends TokenStore {
  @override
  Future<String?> readAccessToken() async => null;

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<String?> readUserId() async => null;

  @override
  Future<String?> readDeviceId() async => null;
}

/// Fails every request at the adapter layer, so the real Dio interceptor chain
/// runs and any `onError` logging would be observed.
class _RefusingAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: const SocketException('Connection refused'),
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Captures forwarded entries instead of performing a real HTTP call.
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(TokenStore());

  final List<AppLogEntry> forwarded = [];
  int calls = 0;
  bool fail = false;

  @override
  Future<bool> logClientEntry(AppLogEntry entry) async {
    calls += 1;
    if (fail) throw StateError('network down');
    forwarded.add(entry);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps a bounded ring buffer of the newest entries', () {
    final logger = AppLogger(maxEntries: 3);

    for (var index = 0; index < 6; index += 1) {
      logger.info('test', 'entry-$index');
    }

    expect(logger.entries.map((entry) => entry.message), ['entry-3', 'entry-4', 'entry-5']);
  });

  test('drops entries older than the retention window', () {
    var now = DateTime.utc(2026, 1, 1, 12);
    final logger = AppLogger(clock: () => now);

    logger.info('test', 'old');
    now = now.add(const Duration(minutes: 61));
    logger.info('test', 'new');

    expect(logger.entries.map((entry) => entry.message), ['new']);
  });

  test('forwards warn and error entries but not info or debug', () async {
    final api = _RecordingApi();
    final logger = AppLogger(api: api);

    logger.debug('test', 'debug');
    logger.info('test', 'info');
    logger.warn('test', 'warn');
    logger.error('test', 'error');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.forwarded.map((entry) => entry.level), [AppLogLevel.warn, AppLogLevel.error]);
  });

  test('never recurses or throws when forwarding fails', () async {
    final api = _RecordingApi()..fail = true;
    final logger = AppLogger(api: api);

    expect(() => logger.error('test', 'boom'), returnsNormally);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(api.calls, 1);
    // The failed forward is not itself logged, so no retry loop forms.
    expect(logger.entries, hasLength(1));
  });

  test('redacts bearer tokens and E2EE envelopes before buffering or sending', () async {
    final api = _RecordingApi();
    final logger = AppLogger(api: api);

    logger.error(
      'test',
      'failed with eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEifQ.c2lnbmF0dXJl',
      meta: {'authorization': 'Bearer abc', 'detail': 'e2ee:v1:abcdef payload'},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final entry = logger.entries.single;
    expect(entry.message, contains('[redacted]'));
    expect(entry.message, isNot(contains('c2lnbmF0dXJl')));
    expect(entry.meta?['authorization'], '[redacted]');
    expect(entry.meta?['detail'], isNot(contains('e2ee:v1:abcdef')));
    expect(api.forwarded.single.meta?['authorization'], '[redacted]');
  });

  test('records a Dio transport failure with connection context', () {
    final logger = AppLogger();

    logger.networkError(
      'dio',
      DioException(
        requestOptions: RequestOptions(path: '/api/v1/conversations'),
        type: DioExceptionType.connectionError,
        error: const SocketException('Connection refused'),
        message: 'Connection refused',
      ),
    );

    final entry = logger.entries.single;
    expect(entry.level, AppLogLevel.error);
    expect(entry.message, contains('network error'));
    expect(entry.meta?['path'], '/api/v1/conversations');
  });

  test('a failing log submission cannot re-enter the logger', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://127.0.0.1:1',
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final adapter = _RefusingAdapter();
    dio.httpClientAdapter = adapter;

    final logger = AppLogger();
    final api = ApiClient(_EmptyTokenStore(), dio: dio, logger: logger);

    final accepted = await api.logClientEntry(
      AppLogEntry(
        ts: DateTime.now(),
        level: AppLogLevel.error,
        tag: 'test',
        message: 'first failure',
      ),
    );

    expect(accepted, isFalse);
    expect(adapter.calls, 1);
    // The transport failure was suppressed for the log path, so the logger
    // received no network-error entry to forward again.
    expect(logger.entries, isEmpty);
  });

  test('an ordinary request does log its transport failure', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://127.0.0.1:1',
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    dio.httpClientAdapter = _RefusingAdapter();

    final logger = AppLogger();
    final api = ApiClient(_EmptyTokenStore(), dio: dio, logger: logger);

    await expectLater(api.conversations(), throwsA(isA<DioException>()));

    expect(logger.entries, hasLength(1));
    expect(logger.entries.single.message, contains('network error'));
  });
}
