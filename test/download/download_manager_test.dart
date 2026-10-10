import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/download/download_manager.dart';
import 'package:soft_local_pai/download/host_validation.dart';
import 'package:soft_local_pai/download/model_catalog.dart';
import 'package:soft_local_pai/models/model_profile.dart';

/// A payload that starts with the real GGUF magic, so the downloader's
/// header check passes. Content past the magic is arbitrary filler —
/// GGUF *structure* validation happens later, in ModelManager.registerFile,
/// which is out of scope for this unit.
Uint8List _ggufPayload(int totalBytes) {
  final bytes = Uint8List(totalBytes);
  bytes[0] = 0x47; // G
  bytes[1] = 0x47; // G
  bytes[2] = 0x55; // U
  bytes[3] = 0x46; // F
  for (var i = 4; i < totalBytes; i++) {
    bytes[i] = i % 256;
  }
  return bytes;
}

CatalogEntry _entry({
  required Uint8List payload,
  String id = 'test-entry',
  int? verifiedSizeBytes,
  String? verifiedSha256,
}) {
  return CatalogEntry(
    id: id,
    displayName: 'Test Model',
    publisher: 'Test Publisher',
    repo: 'test/test-repo',
    fileName: 'test-model.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.small,
    intendedUse: ModelIntendedUse.chat,
    parameterCountLabel: '~1B',
    license: 'Apache License 2.0',
    licenseNotes: 'n/a',
    verifiedFacts: null,
    verifiedSizeBytes: verifiedSizeBytes ?? payload.length,
    verifiedSha256: verifiedSha256 ?? sha256.convert(payload).toString(),
    profile: chatProfile,
    testedOnDevice: false,
  );
}

/// Starts a loopback HTTP server whose GET handler is swapped out per test.
/// All of this is local — no real network or Hugging Face access.
class _TestServer {
  late HttpServer server;
  void Function(HttpRequest request)? onGet;

  Future<Uri> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'HEAD' || request.method == 'GET') {
        onGet?.call(request);
      } else {
        request.response.statusCode = 405;
        await request.response.close();
      }
    });
    return Uri.parse('http://${server.address.address}:${server.port}/file.gguf');
  }

  Future<void> stop() => server.close(force: true);
}

/// Serves [payload] fully, supporting Range requests (so Accept-Ranges is
/// true and a resumed download actually resumes).
void _serveWithRangeSupport(HttpRequest request, Uint8List payload) {
  final range = request.headers.value(HttpHeaders.rangeHeader);
  final res = request.response;
  res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  if (request.method == 'HEAD') {
    res.headers.contentLength = payload.length;
    res.close();
    return;
  }
  if (range != null) {
    final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
    final start = match != null ? int.parse(match.group(1)!) : 0;
    res.statusCode = HttpStatus.partialContent;
    res.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-${payload.length - 1}/${payload.length}',
    );
    res.headers.contentLength = payload.length - start;
    res.add(payload.sublist(start));
  } else {
    res.statusCode = HttpStatus.ok;
    res.headers.contentLength = payload.length;
    res.add(payload);
  }
  res.close();
}

/// Serves [payload] fully every time and never honors Range (no
/// Accept-Ranges header), simulating a host that does not support resume.
void _serveWithoutRangeSupport(HttpRequest request, Uint8List payload) {
  final res = request.response;
  if (request.method == 'HEAD') {
    res.headers.contentLength = payload.length;
    res.close();
    return;
  }
  res.statusCode = HttpStatus.ok;
  res.headers.contentLength = payload.length;
  res.add(payload);
  res.close();
}

void main() {
  late Directory modelsDir;
  late _TestServer testServer;
  late Uri fileUrl;

  setUp(() async {
    modelsDir = await Directory.systemTemp.createTemp('download_test_');
    testServer = _TestServer();
    fileUrl = await testServer.start();
  });

  tearDown(() async {
    await testServer.stop();
    await modelsDir.delete(recursive: true);
  });

  DownloadManager managerAllowingLocalhost({int freeBytes = 1 << 30}) {
    return DownloadManager(
      modelsDir: modelsDir,
      freeBytesAt: (_) async => freeBytes,
      isAllowedHost: (uri) =>
          uri.host == InternetAddress.loopbackIPv4.address ||
          isApprovedModelHost(uri),
      startUrlFor: (_) => fileUrl,
    );
  }

  group('successful download', () {
    test('streams a fresh file to disk and verifies it', () async {
      final payload = _ggufPayload(64 * 1024);
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();

      final resolved = await dm.resolve(entry);
      expect(resolved.liveSizeBytes, payload.length);
      expect(resolved.acceptsRanges, isTrue);
      expect(resolved.sizeMatchesCatalog, isTrue);

      final events = await dm
          .download(entry, resolved, handle: DownloadHandle())
          .toList();
      expect(events.last.receivedBytes, payload.length);

      final finalFile = dm.finalFileFor(entry);
      expect(finalFile.existsSync(), isTrue);
      expect(dm.partFileFor(entry).existsSync(), isFalse);
      expect(await finalFile.readAsBytes(), payload);
    });

    test('progress events report increasing bytes up to the total', () async {
      final payload = _ggufPayload(256 * 1024);
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();
      final resolved = await dm.resolve(entry);

      final events = await dm
          .download(entry, resolved, handle: DownloadHandle())
          .toList();
      for (var i = 1; i < events.length; i++) {
        expect(events[i].receivedBytes, greaterThanOrEqualTo(events[i - 1].receivedBytes));
      }
      expect(events.last.totalBytes, payload.length);
    });
  });

  group('resume', () {
    test('a resumed download continues from the existing .part file', () async {
      final payload = _ggufPayload(256 * 1024);
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();

      // Seed a partial .part file as if an earlier attempt stopped early.
      const already = 100000;
      await dm.partFileFor(entry).writeAsBytes(payload.sublist(0, already));

      final resolved = await dm.resolve(entry);
      expect(dm.existingPartialBytes(entry), already);

      final events = await dm
          .download(entry, resolved, handle: DownloadHandle())
          .toList();
      expect(events.first.receivedBytes, already);
      expect(events.last.receivedBytes, payload.length);
      expect(await dm.finalFileFor(entry).readAsBytes(), payload);
    });

    test('restarts from zero when the server does not support Range', () async {
      final payload = _ggufPayload(128 * 1024);
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithoutRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();

      // Stale/bogus partial content that must NOT be trusted or appended to.
      await dm.partFileFor(entry).writeAsBytes(utf8.encode('stale garbage'));

      final resolved = await dm.resolve(entry);
      expect(resolved.acceptsRanges, isFalse);

      final events = await dm
          .download(entry, resolved, handle: DownloadHandle())
          .toList();
      expect(events.last.receivedBytes, payload.length);
      expect(await dm.finalFileFor(entry).readAsBytes(), payload);
    });
  });

  group('cancellation', () {
    test('cancel mid-stream throws DownloadCancelledException', () async {
      final payload = _ggufPayload(4 * 1024 * 1024);
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();
      final resolved = await dm.resolve(entry);

      final handle = DownloadHandle();
      final completer = Completer<Object>();
      final sub = dm.download(entry, resolved, handle: handle).listen(
        (p) {
          if (p.receivedBytes > 0) handle.cancel();
        },
        onError: completer.complete,
        onDone: () {
          if (!completer.isCompleted) completer.complete('done-without-error');
        },
      );
      final result = await completer.future;
      await sub.cancel();
      expect(result, isA<DownloadCancelledException>());
      expect(dm.partFileFor(entry).existsSync(), isTrue);
    });
  });

  group('insufficient storage', () {
    test('refuses to start when free space is too low', () async {
      final payload = _ggufPayload(10 * 1024 * 1024);
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost(freeBytes: 1024);
      final resolved = await dm.resolve(entry);

      await expectLater(
        dm.download(entry, resolved, handle: DownloadHandle()).toList(),
        throwsA(isA<InsufficientStorageException>()),
      );
      expect(dm.partFileFor(entry).existsSync(), isFalse);
    });
  });

  group('integrity', () {
    test('rejects a file whose checksum does not match', () async {
      final payload = _ggufPayload(32 * 1024);
      final entry = _entry(
        payload: payload,
        verifiedSha256: sha256.convert(utf8.encode('not the real payload')).toString(),
      );
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();
      final resolved = await dm.resolve(entry);

      await expectLater(
        dm.download(entry, resolved, handle: DownloadHandle()).toList(),
        throwsA(isA<DownloadIntegrityException>()),
      );
      expect(dm.partFileFor(entry).existsSync(), isFalse);
      expect(dm.finalFileFor(entry).existsSync(), isFalse);
    });

    test('rejects a file that is not GGUF (bad magic)', () async {
      final payload = Uint8List.fromList(utf8.encode('not a gguf file at all....'));
      final entry = _entry(payload: payload);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();
      final resolved = await dm.resolve(entry);

      await expectLater(
        dm.download(entry, resolved, handle: DownloadHandle()).toList(),
        throwsA(isA<DownloadIntegrityException>()),
      );
      expect(dm.partFileFor(entry).existsSync(), isFalse);
    });
  });

  group('size drift', () {
    test('refuses to download when the live size no longer matches the catalog', () async {
      final payload = _ggufPayload(10 * 1024 * 1024);
      final entry = _entry(payload: payload, verifiedSizeBytes: payload.length + 100 * 1024 * 1024);
      testServer.onGet = (r) => _serveWithRangeSupport(r, payload);
      final dm = managerAllowingLocalhost();
      final resolved = await dm.resolve(entry);
      expect(resolved.sizeMatchesCatalog, isFalse);

      await expectLater(
        dm.download(entry, resolved, handle: DownloadHandle()).toList(),
        throwsA(isA<DownloadException>()),
      );
      expect(dm.partFileFor(entry).existsSync(), isFalse);
    });
  });

  group('redirect host validation', () {
    test('follows a redirect to an allowed host', () async {
      final payload = _ggufPayload(16 * 1024);
      final entry = _entry(payload: payload);

      final redirectTargetServer = _TestServer();
      final targetUrl = await redirectTargetServer.start();
      redirectTargetServer.onGet = (r) => _serveWithRangeSupport(r, payload);

      testServer.onGet = (r) {
        r.response.statusCode = HttpStatus.found;
        r.response.headers.set(HttpHeaders.locationHeader, targetUrl.toString());
        r.response.close();
      };

      final dm = DownloadManager(
        modelsDir: modelsDir,
        freeBytesAt: (_) async => 1 << 30,
        isAllowedHost: (uri) => uri.host == InternetAddress.loopbackIPv4.address,
        startUrlFor: (_) => fileUrl,
      );

      final resolved = await dm.resolve(entry);
      expect(resolved.liveSizeBytes, payload.length);
      await redirectTargetServer.stop();
    });

    test('refuses to follow a redirect to a host outside the allow-list', () async {
      final entry = _entry(payload: _ggufPayload(1024));
      testServer.onGet = (r) {
        r.response.statusCode = HttpStatus.found;
        r.response.headers.set(
          HttpHeaders.locationHeader,
          'https://not-on-the-allow-list.example.com/file.gguf',
        );
        r.response.close();
      };

      final dm = managerAllowingLocalhost();
      await expectLater(
        dm.resolve(entry),
        throwsA(isA<HostNotApprovedException>()),
      );
    });
  });
}
