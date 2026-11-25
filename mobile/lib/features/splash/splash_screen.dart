import 'package:material_ui/material_ui.dart';

/// Minimal neutral surface shown while the persisted session is being read.
///
/// It paints only the theme's scaffold background — the same tone as the native
/// Android launch background — so the handoff from the OS splash to the first
/// Flutter frame is seamless and a returning user never sees the login screen
/// flash before the chat list.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SizedBox.expand());
  }
}
