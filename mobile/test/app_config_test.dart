import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('defaults target the Android emulator host', () {
      expect(AppConfig.apiBaseUrl, 'http://10.0.2.2:8080');
      expect(AppConfig.wsBaseUrl, 'ws://10.0.2.2:8081');
    });

    test('builds the gateway URI with the access token as a query parameter', () {
      final uri = AppConfig.wsUri('token-with+/special=chars');

      expect(uri.path, '/ws');
      expect(uri.queryParameters['token'], 'token-with+/special=chars');
      // The contract requires the token to be query-encoded on Android.
      expect(uri.toString(), contains('token=token-with%2B%2Fspecial%3Dchars'));
    });
  });
}
