import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/main.dart';

void main() {
  testWidgets('app boots to the home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CpChatApp()));

    expect(find.text('CP Chat'), findsWidgets);
    expect(
      find.text('Fast, reliable 1:1 and group messaging.'),
      findsOneWidget,
    );
  });
}
