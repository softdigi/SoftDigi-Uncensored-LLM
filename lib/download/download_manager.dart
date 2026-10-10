import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/memory_estimator.dart';
import 'host_validation.dart';
import 'model_catalog.dart';

/// Cooperative cancellation for one [DownloadManager.download] call. Cancel
/// leaves the `.part` file in place so a later call can resume.
class DownloadHandle {
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool get isCancelled => _cancelled;
}

enum DownloadPhase { resolving, downloading, verifying }

class DownloadProgress {
  const DownloadProgress({
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final DownloadPhase phase;
  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes <= 0 ? 0 : receivedBytes / totalBytes;
}

class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class InsufficientStorageException implements Exception {
  const InsufficientStorageException(this.neededBytes, this.freeBytes);

  final int neededBytes;
  final int freeBytes;

  @override
  String toString() =>
      'not enough free storage: need ${(neededBytes / mib).ceil()} MB, '
      'have ${(freeBytes / mib).floor()} MB free';
}

class DownloadIntegrityException implements Exception {
  const DownloadIntegrityException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when the download was cancelled through [DownloadHandle.cancel].
/// The `.part` file is left untouched so Resume/Retry can continue from it.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'download cancelled';
}

/// What a HEAD check found, after following and validating every redirect
/// hop. Never trusts the catalog's baked-in size on its own — this is the
/// live number a download is actually checked and sized against.
class ResolvedDownload {
  const ResolvedDownload({
    required this.finalUri,
    required this.liveSizeBytes,
    required this.acceptsRanges,
    required this.sizeMatchesCatalog,
  });

  final Uri finalUri;
  final int liveSizeBytes;
  final bool acceptsRanges;

  /// False when the live size differs from [CatalogEntry.verifiedSizeBytes]
  /// by more than [DownloadManager.sizeDriftToleranceBytes]. The download is
  /// refused in that case rather than trusting either number.
  final bool sizeMatchesCatalog;
}

const int _maxRedirects = 8;

/// Streams one catalog model into [modelsDir] as `<fileName>.part`, then
/// renames it to its final name once size and sha256 are both verified.
///
/// Every byte is streamed straight to disk — the response body is never
/// buffered in memory. Interrupted downloads resume via HTTP Range requests
/// when the server supports them; when it does not, or when a resumed
/// request comes back as 200 instead of 206, the partial file is restarted
/// rather than silently treated as complete.
class DownloadManager {
  DownloadManager({
    required this.modelsDir,
    required this.freeBytesAt,
    bool Function(Uri uri)? isAllowedHost,
    Uri Function(CatalogEntry entry)? startUrlFor,
  }) : _client = HttpClient(),
       _isAllowedHost = isAllowedHost ?? isApprovedModelHost,
       _startUrlFor =
           startUrlFor ??
           ((entry) => modelFileUrl(repo: entry.repo, fileName: entry.fileName));

  final Directory modelsDir;

  /// Reads free space (in bytes) on the filesystem containing [path].
  final Future<int> Function(String path) freeBytesAt;

  final HttpClient _client;

  /// Host policy applied to the initial URL and every redirect hop. Always
  /// [isApprovedModelHost] in production; tests may widen this to exercise
  /// the download/resume/cancel logic against a local test server, without
  /// weakening what the app itself ever uses.
  final bool Function(Uri uri) _isAllowedHost;

  /// Builds the URL [resolve] starts from for a catalog entry. Always the
  /// real Hugging Face URL in production; overridable in tests.
  final Uri Function(CatalogEntry entry) _startUrlFor;

  /// Flat tolerance between a catalog entry's baked-in size and the size a
  /// live HEAD check reports. Beyond this, the file is treated as changed
  /// since this catalog was verified, and the download is refused.
  static const int sizeDriftToleranceBytes = 32 * mib;

  /// Kept free on top of the bytes still needed, for the rest of the system.
  static const int storageSafetyMarginBytes = 256 * mib;

  File partFileFor(CatalogEntry entry) =>
      File('${modelsDir.path}/${entry.fileName}.part');

  File finalFileFor(CatalogEntry entry) =>
      File('${modelsDir.path}/${entry.fileName}');

  int existingPartialBytes(CatalogEntry entry) {
    final f = partFileFor(entry);
    return f.existsSync() ? f.lengthSync() : 0;
  }

  void deletePartialDownload(CatalogEntry entry) {
    final f = partFileFor(entry);
    if (f.existsSync()) f.deleteSync();
  }

  /// Issues [method] ("HEAD" or "GET") against [uri], manually following any
  /// redirect so every hop — including the Hugging Face CDN host the
  /// request eventually lands on — is checked against [isApprovedModelHost]
  /// before being followed. Never delegates this to `HttpClient`'s own
  /// automatic redirect following, which would not check hosts at all.
  Future<({HttpClientResponse response, Uri finalUri})> _openValidated(
    Uri uri, {
    required String method,
    String? rangeHeader,
  }) async {
    var target = uri;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final request = method == 'HEAD'
          ? await _client.headUrl(target)
          : await _client.getUrl(target);
      request.followRedirects = false;
      if (rangeHeader != null) {
        request.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }
      final response = await request.close();

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw const DownloadException('redirect with no location header');
        }
        final next = Uri.tryParse(location);
        if (next == null || !_isAllowedHost(next)) {
          throw HostNotApprovedException(location);
        }
        target = next;
        continue;
      }
      return (response: response, finalUri: target);
    }
    throw const DownloadException('too many redirects');
  }

  /// HEAD-checks [entry]'s file through [_openValidated].
  Future<ResolvedDownload> resolve(CatalogEntry entry) async {
    final uri = _startUrlFor(entry);
    if (!_isAllowedHost(uri)) {
      throw HostNotApprovedException(uri.toString());
    }
    final (response: response, finalUri: finalUri) = await _openValidated(
      uri,
      method: 'HEAD',
    );
    await response.drain<void>();

    if (response.statusCode != 200) {
      throw DownloadException(
        'could not check the file (HTTP ${response.statusCode})',
      );
    }

    final liveSize = response.contentLength;
    if (liveSize < 0) {
      throw const DownloadException('the server did not report a file size');
    }
    final acceptsRanges =
        response.headers.value(HttpHeaders.acceptRangesHeader) == 'bytes';
    final drift = (liveSize - entry.verifiedSizeBytes).abs();
    return ResolvedDownload(
      finalUri: finalUri,
      liveSizeBytes: liveSize,
      acceptsRanges: acceptsRanges,
      sizeMatchesCatalog: drift <= sizeDriftToleranceBytes,
    );
  }

  /// Downloads [entry], resuming from any existing `.part` file. Yields
  /// progress as bytes arrive; never buffers the body in memory. On success,
  /// [finalFileFor] exists, its size matches [resolved], and its sha256
  /// matches [CatalogEntry.verifiedSha256] — ready for
  /// `ModelManager.registerFile`.
  Stream<DownloadProgress> download(
    CatalogEntry entry,
    ResolvedDownload resolved, {
    required DownloadHandle handle,
  }) async* {
    if (!resolved.sizeMatchesCatalog) {
      throw DownloadException(
        'the file on the server (${(resolved.liveSizeBytes / mib).round()} MB) no '
        'longer matches what was verified for this catalog '
        '(${(entry.verifiedSizeBytes / mib).round()} MB); refusing to download',
      );
    }

    final part = partFileFor(entry);
    var resumeFrom = part.existsSync() ? part.lengthSync() : 0;
    if (resumeFrom > resolved.liveSizeBytes) {
      // Leftover from a different file version. Start over.
      resumeFrom = 0;
      part.deleteSync();
    }
    if (!resolved.acceptsRanges && resumeFrom > 0) {
      resumeFrom = 0;
      part.deleteSync();
    }

    final remaining = resolved.liveSizeBytes - resumeFrom;
    final free = await freeBytesAt(modelsDir.path);
    if (free < remaining + storageSafetyMarginBytes) {
      throw InsufficientStorageException(
        remaining + storageSafetyMarginBytes,
        free,
      );
    }

    yield DownloadProgress(
      phase: DownloadPhase.downloading,
      receivedBytes: resumeFrom,
      totalBytes: resolved.liveSizeBytes,
    );

    final (response: response, finalUri: _) = await _openValidated(
      resolved.finalUri,
      method: 'GET',
      rangeHeader: resumeFrom > 0 ? 'bytes=$resumeFrom-' : null,
    );

    if (resumeFrom > 0 && response.statusCode == 200) {
      // Server ignored the Range request. Restart from scratch using this
      // response's full body rather than appending onto stale bytes.
      resumeFrom = 0;
      if (part.existsSync()) part.deleteSync();
    } else if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw DownloadException(
        'download failed (HTTP ${response.statusCode})',
      );
    }

    final sink = part.openWrite(
      mode: resumeFrom > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var received = resumeFrom;
    try {
      await for (final chunk in response) {
        if (handle.isCancelled) {
          throw const DownloadCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        yield DownloadProgress(
          phase: DownloadPhase.downloading,
          receivedBytes: received,
          totalBytes: resolved.liveSizeBytes,
        );
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (received != resolved.liveSizeBytes) {
      throw DownloadException(
        'the download ended early (${(received / mib).round()} of '
        '${(resolved.liveSizeBytes / mib).round()} MB) — tap Resume to continue',
      );
    }

    yield DownloadProgress(
      phase: DownloadPhase.verifying,
      receivedBytes: received,
      totalBytes: resolved.liveSizeBytes,
    );

    final head = await part.open();
    final magic = await head.read(4);
    await head.close();
    if (magic.length != 4 ||
        magic[0] != 0x47 ||
        magic[1] != 0x47 ||
        magic[2] != 0x55 ||
        magic[3] != 0x46) {
      part.deleteSync();
      throw const DownloadIntegrityException(
        'the downloaded file is not a GGUF file (bad header); it has been removed',
      );
    }

    final digest = await sha256.bind(part.openRead()).first;
    final actualSha256 = digest.toString();
    if (actualSha256 != entry.verifiedSha256) {
      part.deleteSync();
      throw DownloadIntegrityException(
        'the downloaded file\'s checksum does not match the verified checksum for this '
        'model; it has been removed. This can happen after a corrupted download — retry.',
      );
    }

    final finalFile = finalFileFor(entry);
    if (finalFile.existsSync()) finalFile.deleteSync();
    part.renameSync(finalFile.path);

    yield DownloadProgress(
      phase: DownloadPhase.verifying,
      receivedBytes: received,
      totalBytes: resolved.liveSizeBytes,
    );
  }

  void close() => _client.close(force: true);
}
