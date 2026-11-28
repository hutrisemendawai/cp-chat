import 'package:livekit_client/livekit_client.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/models/call_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/user_avatar.dart';

/// Adaptive participant grid for group calls:
///  - 1 participant -> full canvas
///  - 2 participants -> split vertical stack
///  - 3-4 participants -> 2x2 grid
///  - 5-6 participants -> 2x3 grid
///  - 7+ participants -> paged 2x3 grid (`PageView`)
///
/// Tapping any tile pins it to the main stage with a horizontal filmstrip below.
/// Notifies [onVisibleParticipantsChanged] whenever the visible set changes so
/// off-screen remote video tracks are unsubscribed to protect Android decoders.
class GroupCallGrid extends StatefulWidget {
  const GroupCallGrid({
    super.key,
    required this.participants,
    required this.onVisibleParticipantsChanged,
  });

  final List<CallParticipantView> participants;
  final ValueChanged<Set<String>> onVisibleParticipantsChanged;

  @override
  State<GroupCallGrid> createState() => _GroupCallGridState();
}

class _GroupCallGridState extends State<GroupCallGrid> {
  static const int _pageSize = 6;
  final PageController _pageController = PageController();
  int _currentPage = 0;
  String? _pinnedUserId;
  Set<String> _lastReportedVisible = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportVisible());
  }

  @override
  void didUpdateWidget(covariant GroupCallGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pinnedUserId != null &&
        !widget.participants.any((p) => p.userId == _pinnedUserId)) {
      _pinnedUserId = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportVisible());
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _reportVisible() {
    if (!mounted) return;
    final visible = <String>{};
    if (_pinnedUserId != null) {
      visible.add(_pinnedUserId!);
      for (final p in widget.participants.take(4)) {
        visible.add(p.userId);
      }
    } else {
      final start = _currentPage * _pageSize;
      final end = (start + _pageSize).clamp(0, widget.participants.length);
      for (var i = start; i < end; i++) {
        visible.add(widget.participants[i].userId);
      }
    }
    if (visible.length == _lastReportedVisible.length &&
        visible.containsAll(_lastReportedVisible)) {
      return;
    }
    _lastReportedVisible = visible;
    widget.onVisibleParticipantsChanged(visible);
  }

  void _togglePin(String userId) {
    setState(() {
      _pinnedUserId = _pinnedUserId == userId ? null : userId;
    });
    _reportVisible();
  }

  @override
  Widget build(BuildContext context) {
    final participants = widget.participants;
    if (participants.isEmpty) {
      return const Center(
        child: Text(
          'Waiting for others to join...',
          style: TextStyle(color: Colors.white70, fontSize: 16),
        ),
      );
    }

    if (_pinnedUserId != null) {
      final pinned = participants.firstWhere(
        (p) => p.userId == _pinnedUserId,
        orElse: () => participants.first,
      );
      final others = participants.where((p) => p.userId != pinned.userId).toList();
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _ParticipantTile(
                participant: pinned,
                pinned: true,
                onTap: () => _togglePin(pinned.userId),
              ),
            ),
          ),
          if (others.isNotEmpty)
            SizedBox(
              height: 112,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                itemCount: others.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final p = others[index];
                  return SizedBox(
                    width: 96,
                    child: _ParticipantTile(
                      participant: p,
                      compact: true,
                      onTap: () => _togglePin(p.userId),
                    ),
                  );
                },
              ),
            ),
        ],
      );
    }

    if (participants.length == 1) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: _ParticipantTile(
          participant: participants.first,
          onTap: () => _togglePin(participants.first.userId),
        ),
      );
    }

    if (participants.length == 2) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Expanded(
              child: _ParticipantTile(
                participant: participants[0],
                onTap: () => _togglePin(participants[0].userId),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _ParticipantTile(
                participant: participants[1],
                onTap: () => _togglePin(participants[1].userId),
              ),
            ),
          ],
        ),
      );
    }

    if (participants.length <= _pageSize) {
      return _buildGridPage(participants);
    }

    final pageCount = (participants.length / _pageSize).ceil();
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: pageCount,
            onPageChanged: (page) {
              setState(() => _currentPage = page);
              _reportVisible();
            },
            itemBuilder: (_, pageIndex) {
              final start = pageIndex * _pageSize;
              final end = (start + _pageSize).clamp(0, participants.length);
              return _buildGridPage(participants.sublist(start, end));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              pageCount,
              (i) => Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _currentPage
                      ? AppColors.whatsappEmerald
                      : Colors.white30,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGridPage(List<CallParticipantView> pageItems) {
    final rows = pageItems.length <= 4 ? 2 : 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - 24) / 2;
        final tileHeight = (constraints.maxHeight - ((rows + 1) * 8)) / rows;
        final aspectRatio =
            tileHeight > 0 ? (tileWidth / tileHeight).clamp(0.5, 2.0) : 0.75;

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: aspectRatio,
          ),
          itemCount: pageItems.length,
          itemBuilder: (_, index) {
            final p = pageItems[index];
            return _ParticipantTile(
              participant: p,
              onTap: () => _togglePin(p.userId),
            );
          },
        );
      },
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.participant,
    required this.onTap,
    this.pinned = false,
    this.compact = false,
  });

  final CallParticipantView participant;
  final VoidCallback onTap;
  final bool pinned;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hasVideo = participant.videoEnabled && participant.videoTrack != null;
    final borderColor = participant.isSpeaking
        ? AppColors.whatsappEmerald
        : Colors.white.withValues(alpha: 0.14);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: const Color(0xFF1F2C34),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: borderColor,
            width: participant.isSpeaking ? 2.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasVideo)
              VideoTrackRenderer(
                participant.videoTrack!,
                fit: VideoViewFit.cover,
              )
            else
              Center(
                child: UserAvatarWithStatus(
                  avatarKey: participant.avatarUrl,
                  name: participant.displayName,
                  radius: compact ? 22 : 34,
                  showStatus: false,
                ),
              ),
            if (pinned)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.push_pin,
                    size: 14,
                    color: AppColors.whatsappEmerald,
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (participant.audioMuted) ...[
                            const Icon(
                              Icons.mic_off,
                              size: 13,
                              color: Colors.redAccent,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              participant.isLocal
                                  ? '${participant.displayName} (You)'
                                  : participant.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
