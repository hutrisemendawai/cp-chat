import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/shared/widgets/status_badge.dart';
import 'package:cp_chat/shared/widgets/status_colors.dart';
import 'package:cp_chat/shared/widgets/user_avatar.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('status colours', () {
    test('map each presence status to its colour', () {
      expect(StatusColors.of('online'), StatusColors.online);
      expect(StatusColors.of('idle'), StatusColors.idle);
      expect(StatusColors.of('dnd'), StatusColors.dnd);
      expect(StatusColors.of('offline'), StatusColors.offline);
      expect(StatusColors.of('invisible'), StatusColors.offline);
      expect(StatusColors.of(null), StatusColors.offline);
    });

    test('uses the exact Stitch presence palette', () {
      expect(StatusColors.online, const Color(0xFF25D366));
      expect(StatusColors.idle, const Color(0xFFF59E0B));
      expect(StatusColors.dnd, const Color(0xFFEF4444));
      expect(StatusColors.offline, const Color(0xFF86948D));
    });
  });

  group('StatusBadge', () {
    for (final status in ['online', 'idle', 'dnd', 'offline', 'invisible']) {
      testWidgets('renders $status without overflow', (tester) async {
        await tester.pumpWidget(_wrap(StatusBadge(status: status)));
        expect(find.byType(StatusBadge), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('treats invisible as offline', (tester) async {
      await tester.pumpWidget(_wrap(const StatusBadge(status: 'invisible', size: 16)));

      final container = tester.widget<Container>(
        find.descendant(of: find.byType(StatusBadge), matching: find.byType(Container)).first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, StatusColors.offline);
    });
  });

  group('UserAvatarWithStatus', () {
    testWidgets('falls back to the first letter of the name', (tester) async {
      await tester.pumpWidget(
        _wrap(const UserAvatarWithStatus(name: 'Alice', status: 'online')),
      );

      expect(find.text('A'), findsOneWidget);
      expect(find.byType(StatusBadge), findsOneWidget);
    });

    testWidgets('hides the dot when showStatus is false', (tester) async {
      await tester.pumpWidget(
        _wrap(const UserAvatarWithStatus(name: 'Bob', showStatus: false)),
      );

      expect(find.text('B'), findsOneWidget);
      expect(find.byType(StatusBadge), findsNothing);
    });

    testWidgets('shows a question mark for an empty name', (tester) async {
      await tester.pumpWidget(_wrap(const UserAvatarWithStatus(name: '   ')));
      expect(find.text('?'), findsOneWidget);
    });
  });
}
