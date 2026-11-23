import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Top-level navigation shell across Chats, People and Profile.
///
/// Each branch keeps its own navigation stack (via
/// `StatefulShellRoute.indexedStack`), so switching tabs preserves scroll
/// position and an in-progress conversation. Detail screens are declared on the
/// root navigator and therefore cover this bar.
///
/// Styling comes from the Stitch design system: a `surface-container` bar with
/// pill-shaped indicators behind the active destination icon.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: const Icon(Icons.group_outlined),
            selectedIcon: const Icon(Icons.group),
            label: 'People',
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
