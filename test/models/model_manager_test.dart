import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/models/crash_marker.dart';
import 'package:soft_local_pai/models/memory_estimator.dart';
import 'package:soft_local_pai/models/model_manager.dart';
import 'package:soft_local_pai/models/model_profile.dart';

import 'fake_runtime.dart';

void main() {
  late Directory root;
  late FakeRuntime runtime;
  late int freeRam;

  ModelManager makeManager() => ModelManager(
    rootDir: root,
    runtime: runtime,
    availableRamBytes: () async => freeRam,
    threads: 4,
  );

  // Writes a fake GGUF (magic plus padding) into the models folder.
  File writeGguf(String name, {String magic = 'GGUF'}) {
    final f = File('${root.path}/models/$name');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(
      Uint8List.fromList([...magic.codeUnits, ...List.filled(64, 0)]),
    );
    return f;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('mgr_test');
    runtime = FakeRuntime();
    freeRam = 6 * gib;
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'registers a GGUF file with its metadata and survives a restart',
    () async {
      writeGguf('llama.gguf');
      final mgr = makeManager()..init();
      final m = await mgr.registerFile(
        fileName: 'llama.gguf',
        displayName: 'Llama',
        profile: chatProfile,
      );
      expect(m.facts.nLayer, 28);
      expect(mgr.models, hasLength(1));

      final again = makeManager()..init();
      expect(again.models.single.displayName, 'Llama');
      expect(again.models.single.facts.nHeadKv, 8);
    },
  );

  test('rejects a file without the GGUF magic and removes it', () async {
    writeGguf('bad.gguf', magic: 'ZIP!');
    final mgr = makeManager()..init();
    await expectLater(
      mgr.registerFile(
        fileName: 'bad.gguf',
        displayName: 'bad',
        profile: chatProfile,
      ),
      throwsA(isA<ModelManagerException>()),
    );
    expect(File('${root.path}/models/bad.gguf').existsSync(), isFalse);
    expect(mgr.models, isEmpty);
  });

  test(
    'activation clamps the requested context to the memory budget',
    () async {
      writeGguf('llama.gguf');
      final mgr = makeManager()..init();
      final m = await mgr.registerFile(
        fileName: 'llama.gguf',
        displayName: 'Llama',
        profile: chatProfile,
      );
      final report = await mgr.activate(
        m.id,
        profile: chatProfile,
        requestedContext: 1000000,
      );
      expect(report.contextTokens, 8192);
      expect(report.contextClamped, isTrue);
      expect(runtime.loadedContext, 8192);
      expect(mgr.active?.id, m.id);
    },
  );

  test('activation refuses when free RAM is below the estimate', () async {
    writeGguf('llama.gguf');
    final mgr = makeManager()..init();
    final m = await mgr.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama',
      profile: chatProfile,
    );
    freeRam = 1 * gib;
    await expectLater(
      mgr.activate(m.id, profile: chatProfile),
      throwsA(isA<ModelManagerException>()),
    );
    expect(runtime.calls, isNot(contains('load')));
    expect(mgr.active, isNull);
  });

  test('switching unloads the current model before loading the next', () async {
    writeGguf('a.gguf');
    writeGguf('b.gguf');
    final mgr = makeManager()..init();
    final a = await mgr.registerFile(
      fileName: 'a.gguf',
      displayName: 'A',
      profile: chatProfile,
    );
    final b = await mgr.registerFile(
      fileName: 'b.gguf',
      displayName: 'B',
      profile: codingProfile,
    );
    await mgr.activate(a.id, profile: chatProfile);
    runtime.calls.clear();
    await mgr.activate(b.id, profile: codingProfile);
    expect(runtime.calls, ['unload', 'load']);
    expect(mgr.active?.id, b.id);
  });

  test(
    'a load that dies with the process quarantines the model on the next start',
    () async {
      writeGguf('llama.gguf');
      final first = makeManager()..init();
      final m = await first.registerFile(
        fileName: 'llama.gguf',
        displayName: 'Llama',
        profile: chatProfile,
      );
      // Simulate a process death during load: the marker is written and never cleared.
      CrashMarker(File('${root.path}/models/loading.marker')).begin(m.id);

      final restarted = makeManager()..init();
      expect(restarted.byId(m.id)!.isQuarantined, isTrue);
      expect(restarted.recoveryNotes.single, contains('quarantined'));
      await expectLater(
        restarted.activate(m.id, profile: chatProfile),
        throwsA(isA<ModelManagerException>()),
      );

      restarted.clearQuarantine(m.id);
      final report = await restarted.activate(m.id, profile: chatProfile);
      expect(report.model.isQuarantined, isFalse);
    },
  );

  test('a failed load clears the marker and does not quarantine', () async {
    writeGguf('llama.gguf');
    final mgr = makeManager()..init();
    final m = await mgr.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama',
      profile: chatProfile,
    );
    runtime.failLoad = true;
    await expectLater(
      mgr.activate(m.id, profile: chatProfile),
      throwsA(isA<ModelManagerException>()),
    );
    expect(
      CrashMarker(File('${root.path}/models/loading.marker')).takeStale(),
      isNull,
    );
    final restarted = makeManager()..init();
    expect(restarted.byId(m.id)!.isQuarantined, isFalse);
  });

  test('deleting the active model unloads it and removes the file', () async {
    writeGguf('llama.gguf');
    final mgr = makeManager()..init();
    final m = await mgr.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama',
      profile: chatProfile,
    );
    await mgr.activate(m.id, profile: chatProfile);
    await mgr.delete(m.id);
    expect(mgr.active, isNull);
    expect(mgr.models, isEmpty);
    expect(File('${root.path}/models/llama.gguf').existsSync(), isFalse);
    expect(runtime.calls, contains('unload'));
  });

  test('init drops registry entries whose file is missing', () async {
    writeGguf('llama.gguf');
    final mgr = makeManager()..init();
    await mgr.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama',
      profile: chatProfile,
    );
    File('${root.path}/models/llama.gguf').deleteSync();
    final restarted = makeManager()..init();
    expect(restarted.models, isEmpty);
    expect(restarted.recoveryNotes.single, contains('file missing'));
  });
}
