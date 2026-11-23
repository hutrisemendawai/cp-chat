import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/media/media_service.dart';
import '../../core/providers.dart';

/// Circular avatar backed by a private media object. Falls back to [fallback]
/// when no avatar is set or the image cannot be loaded.
///
/// Drawn on the design system's `secondary-container` tone so initials and the
/// image share one surface.
class MediaAvatar extends ConsumerWidget {
  const MediaAvatar({
    super.key,
    required this.objectKey,
    required this.fallback,
    this.radius = 20,
  });

  final String? objectKey;
  final Widget fallback;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget circle(Widget child) => Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            shape: BoxShape.circle,
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: child,
        );

    final key = objectKey;
    if (key == null) return circle(fallback);

    final api = ref.watch(apiClientProvider);
    final token = ref.watch(accessTokenProvider).value;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};

    return circle(
      CachedNetworkImage(
        imageUrl: api.mediaUrl(key),
        httpHeaders: headers,
        fit: BoxFit.cover,
        width: radius * 2,
        height: radius * 2,
        placeholder: (context, url) => const SizedBox.shrink(),
        errorWidget: (context, url, error) => Center(child: fallback),
      ),
    );
  }
}

/// Renders an image message. The stored content is an object key; the API
/// authorizes the caller and redirects to a short-lived presigned URL, which
/// [CachedNetworkImage] follows transparently.
class ImageMessage extends ConsumerWidget {
  const ImageMessage({super.key, required this.content});

  final String content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    final theme = Theme.of(context);
    final (:key, :caption) = splitMediaContent(content);
    final token = ref.watch(accessTokenProvider).value;
    final headers = token == null
        ? const <String, String>{}
        : {'Authorization': 'Bearer $token'};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CachedNetworkImage(
            imageUrl: api.mediaUrl(key),
            httpHeaders: headers,
            fit: BoxFit.cover,
            width: 240,
            placeholder: (context, url) => const SizedBox(
              width: 240,
              height: 160,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            errorWidget: (context, url, error) => Container(
              width: 240,
              height: 120,
              color: theme.colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined),
                  SizedBox(height: 4),
                  Text('Image unavailable'),
                ],
              ),
            ),
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(caption, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}

/// Renders a file attachment as a tappable card. Opening hands the download to
/// the platform browser/download manager; the token is passed in the query
/// because an external handler cannot attach the bearer header.
class FileMessage extends ConsumerWidget {
  const FileMessage({super.key, required this.content});

  final String content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    final theme = Theme.of(context);
    final (:key, :caption) = splitMediaContent(content);
    final fileName = key.split('/').last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => _open(context, api.mediaUrl(key), ref.read(accessTokenProvider).value),
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('Download'),
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(caption, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }

  Future<void> _open(BuildContext context, String url, String? token) async {
    final uri = token == null
        ? Uri.parse(url)
        : Uri.parse(url).replace(queryParameters: {'token': token});
    final messenger = ScaffoldMessenger.of(context);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        messenger.showSnackBar(const SnackBar(content: Text('Could not open the file')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open the file: $error')));
    }
  }
}
