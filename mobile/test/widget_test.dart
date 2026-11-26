import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/notifications/local_notification_service.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/features/auth/auth_screen.dart';
import 'package:cp_chat/main.dart';

/// A resolved signed-out session, so the router lands on the sign-in screen
/// without waiting on storage.
class _SignedOutAuth extends AuthController {
  @override
  AuthState build() => const AuthState.unauthenticated();
}

/// No-op notification tray so the platform plugin is never touched.
class _FakeNotifications extends LocalNotificationService {
  @override
  Future<void> initialize({bool checkLaunchDetails = true}) async {}

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> dispose() async {}

  @override
  String? get coldStartConversationId => null;
}

void main() {
  testWidgets('signed-out users are routed to the sign-in screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_SignedOutAuth.new),
          localNotificationServiceProvider.overrideWithValue(_FakeNotifications()),
          bootstrapProvider.overrideWith((ref) async {}),
        ],
        child: const CpChatApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('auth screen validates the form before submitting', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AuthScreen())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email or username'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  testWidgets('registration mode asks for a username, name and a longer password',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AuthScreen())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your account'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Display name'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone or email'),
      'new@example.com',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'new_person');
    await tester.enterText(find.widgetWithText(TextFormField, 'Display name'), 'New Person');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'short');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Use at least 8 characters'), findsOneWidget);
  });

  testWidgets('registration rejects a username with an invalid character',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AuthScreen())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone or email'),
      'new@example.com',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'bad@name');
    await tester.enterText(find.widgetWithText(TextFormField, 'Display name'), 'New Person');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Only letters, numbers, "_" and "." are allowed'), findsOneWidget);
  });

  testWidgets('password visibility toggles', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AuthScreen())),
    );
    await tester.pumpAndSettle();

    EditableText passwordField() =>
        tester.widget<EditableText>(find.byType(EditableText).last);

    expect(passwordField().obscureText, isTrue);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();

    expect(passwordField().obscureText, isFalse);
  });
}
