import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../logging/app_logger.dart';
import '../models/models.dart';
import '../network/api_client.dart';
import '../storage/app_dirs.dart';

/// Attaches media to a conversation: compress (images only), upload through the
/// API, then hand back the object key to put in a websocket message.
///
/// Uploads go to `POST /api/v1/media/upload`, so a physical device only needs
/// connectivity to the API host. The API streams the bytes to object storage
/// server-side; the device never has to reach MinIO/S3 directly.
class MediaService {
  MediaService(
    this._api, {
    this.logger,
    this.uploadTempDir,
  });

  final ApiClient _api;
  final AppLogger? logger;
  final Future<Directory> Function()? uploadTempDir;

  /// Compression target. Large camera photos are typically 3–8 MB; 1600 px at
  /// quality 80 lands well under a megabyte for most screenshots and photos.
  static const int _maxDimension = 1600;
  static const int _quality = 80;

  /// Prepares and uploads an image file, returning the object key. The file is
  /// compressed to a temporary copy first.
  Future<String> uploadImage({
    required File file,
    void Function(int sent, int total)? onProgress,
  }) async {
    final prepared = await _compressImage(file);
    try {
      final contentType = _contentTypeFor(prepared.path, fallback: 'image/jpeg');
      return await _upload(
        file: prepared,
        filename: _fileName(prepared.path),
        contentType: contentType,
        onProgress: onProgress,
      );
    } finally {
      if (prepared.path != file.path) {
        await _deleteQuietly(prepared.path);
      }
    }
  }

  /// Uploads an arbitrary file (document, video, audio) without re-encoding.
  Future<String> uploadFile({
    required File file,
    required String? displayName,
    required String? contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final size = await file.length();
    if (size <= 0) {
      throw ApiException('empty_file', 'That file is empty');
    }
    return _upload(
      file: file,
      filename: displayName ?? _fileName(file.path),
      contentType: contentType ?? _contentTypeFor(file.path),
      onProgress: onProgress,
    );
  }

  Future<String> _upload({
    required File file,
    required String filename,
    required String contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final bytes = await file.readAsBytes();
    try {
      final uploaded = await _api.uploadMedia(
        bytes: bytes,
        filename: filename,
        contentType: contentType,
        onProgress: onProgress,
      );
      return uploaded.objectKey;
    } catch (error) {
      logger?.error('media', 'upload failed', meta: {
        'filename': filename,
        'content_type': contentType,
        'size_bytes': bytes.length,
        'error': error.toString(),
      });
      rethrow;
    }
  }

  /// Compresses an image on-device into the account-scoped upload temp dir.
  /// Falls back to the original file when the platform plugin is unavailable
  /// (e.g. widget tests).
  Future<File> _compressImage(File source) async {
    try {
      final directory = await (uploadTempDir?.call() ?? AppDirs.cache());
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final target = '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        source.absolute.path,
        target,
        minWidth: _maxDimension,
        minHeight: _maxDimension,
        quality: _quality,
        format: CompressFormat.jpeg,
      );
      if (result == null) return source;

      final compressed = File(result.path);
      // Never send a "compressed" file that is larger than the original.
      final originalSize = await source.length();
      final compressedSize = await compressed.length();
      if (compressedSize == 0 || compressedSize >= originalSize) {
        await _deleteQuietly(compressed.path);
        return source;
      }
      return compressed;
    } catch (error) {
      debugPrint('Image compression unavailable, using original: $error');
      return source;
    }
  }

  String _fileName(String path) => path.split(Platform.pathSeparator).last;

  String _contentTypeFor(String path, {String fallback = 'application/octet-stream'}) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.txt')) return 'text/plain';
    return fallback;
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort: temp files are cleaned by the OS.
    }
  }
}

/// Media messages store the object key as their content, optionally carrying a
/// caption after a `|` separator for image/file attachments.
({String key, String? caption}) splitMediaContent(String content) {
  final index = content.indexOf('|');
  if (index < 0) return (key: content, caption: null);
  final caption = content.substring(index + 1);
  return (key: content.substring(0, index), caption: caption.isEmpty ? null : caption);
}

String joinMediaContent(String key, String? caption) =>
    caption == null || caption.isEmpty ? key : '$key|$caption';
