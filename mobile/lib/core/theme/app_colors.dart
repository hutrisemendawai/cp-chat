import 'package:material_ui/material_ui.dart';

/// Design tokens taken verbatim from the Google Stitch project
/// `projects/14662638851741478393` ("WhatsApp Clone UI Theme"), design system
/// `assets/canvas_node_node_7972721565232412322`.
///
/// Colours are copied from that design system's `DESIGN.md` colour block so the
/// Flutter client and the Stitch screens stay in lockstep. Add new colours here
/// from the design system rather than hand-picking them at call sites.
class AppColors {
  const AppColors._();

  /// WhatsApp signature emerald: FABs, send buttons, active pills.
  static const Color whatsappEmerald = Color(0xFF00A884);
  static const Color readReceipt = Color(0xFF53BDEB);

  static const Color statusOnline = Color(0xFF25D366);
  static const Color statusIdle = Color(0xFFF59E0B);
  static const Color statusDnd = Color(0xFFEF4444);
  static const Color statusOffline = Color(0xFF86948D);
}

/// Chat-surface colours that Material 3's [ColorScheme] has no slot for.
///
/// Registered as a [ThemeExtension] so they are read with
/// `Theme.of(context).extension<ChatTheme>()!` and automatically resolve per
/// brightness.
@immutable
class ChatTheme extends ThemeExtension<ChatTheme> {
  const ChatTheme({
    required this.wallpaper,
    required this.bubbleOut,
    required this.onBubbleOut,
    required this.bubbleIn,
    required this.onBubbleIn,
  });

  /// Backdrop behind the message feed.
  final Color wallpaper;

  /// Outgoing (own) message bubble.
  final Color bubbleOut;
  final Color onBubbleOut;

  /// Incoming message bubble.
  final Color bubbleIn;
  final Color onBubbleIn;

  static const light = ChatTheme(
    wallpaper: Color(0xFFEFEAE2),
    bubbleOut: Color(0xFFD9FDD3),
    onBubbleOut: Color(0xFF111B21),
    bubbleIn: Color(0xFFFFFFFF),
    onBubbleIn: Color(0xFF111B21),
  );

  static const dark = ChatTheme(
    wallpaper: Color(0xFF0B141A),
    bubbleOut: Color(0xFF005C4B),
    onBubbleOut: Color(0xFFE9EDEF),
    bubbleIn: Color(0xFF1F2C34),
    onBubbleIn: Color(0xFFE9EDEF),
  );

  @override
  ChatTheme copyWith({
    Color? wallpaper,
    Color? bubbleOut,
    Color? onBubbleOut,
    Color? bubbleIn,
    Color? onBubbleIn,
  }) {
    return ChatTheme(
      wallpaper: wallpaper ?? this.wallpaper,
      bubbleOut: bubbleOut ?? this.bubbleOut,
      onBubbleOut: onBubbleOut ?? this.onBubbleOut,
      bubbleIn: bubbleIn ?? this.bubbleIn,
      onBubbleIn: onBubbleIn ?? this.onBubbleIn,
    );
  }

  @override
  ChatTheme lerp(ThemeExtension<ChatTheme>? other, double t) {
    if (other is! ChatTheme) return this;
    return ChatTheme(
      wallpaper: Color.lerp(wallpaper, other.wallpaper, t)!,
      bubbleOut: Color.lerp(bubbleOut, other.bubbleOut, t)!,
      onBubbleOut: Color.lerp(onBubbleOut, other.onBubbleOut, t)!,
      bubbleIn: Color.lerp(bubbleIn, other.bubbleIn, t)!,
      onBubbleIn: Color.lerp(onBubbleIn, other.onBubbleIn, t)!,
    );
  }
}

/// Convenience accessor so widgets read `context.chatTheme` instead of the
/// verbose extension lookup.
extension ChatThemeAccess on BuildContext {
  ChatTheme get chatTheme =>
      Theme.of(this).extension<ChatTheme>() ?? ChatTheme.light;
}
