/// Compile-time configuration.
///
/// Override for a physical device or a deployed backend:
/// `flutter run --dart-define=API_BASE_URL=https://api.example.com`
/// `flutter run --dart-define=WS_BASE_URL=wss://api.example.com`
///
/// The defaults target the Android emulator, where `10.0.2.2` is the host
/// machine. For USB devices, run `adb reverse tcp:8080 tcp:8080`.
abstract final class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://10.0.2.2:8081',
  );

  static Uri wsUri(String accessToken) =>
      Uri.parse('$wsBaseUrl/ws').replace(queryParameters: {'token': accessToken});
}
