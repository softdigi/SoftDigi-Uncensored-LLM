import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/models/model_list_page.dart';
import 'package:soft_local_pai/models/model_manager.dart';
import 'package:soft_local_pai/models/model_profile.dart';

import 'fake_runtime.dart';

void main() {
  late Directory root;
  late FakeRuntime runtime;

  setUp(() {
    root = Directory.systemTemp.createTempSync('list_page_test');
    runtime = FakeRuntime();
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ModelManager> managerWithOneModel() async {
    final file = File('${root.path}/models/llama.gguf');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      Uint8List.fromList([...'GGUF'.codeUnits, ...List.filled(64, 0)]),
    );
    final mgr = ModelManager(
      rootDir: root,
      runtime: runtime,
      availableRamBytes: () async => 6 * 1024 * 1024 * 1024,
      threads: 4,
    )..init();
    await mgr.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama 3.2 3B (test)',
      profile: chatProfile,
    );
    return mgr;
  }

  testWidgets('lists the model with its profile and memory estimate', (
    tester,
  ) async {
    final mgr = (await tester.runAsync(managerWithOneModel))!;
    await tester.pumpWidget(MaterialApp(home: ModelListPage(manager: mgr)));

    expect(find.text('Llama 3.2 3B (test)'), findsOneWidget);
    expect(find.text(chatProfile.displayName), findsOneWidget);
    expect(find.textContaining('estimated RAM'), findsOneWidget);
    expect(find.text('Not loaded'), findsOneWidget);
    expect(find.text('Load'), findsOneWidget);
  });

  testWidgets('Load activates the model and shows Unload', (tester) async {
    final mgr = (await tester.runAsync(managerWithOneModel))!;
    await tester.pumpWidget(MaterialApp(home: ModelListPage(manager: mgr)));

    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();

    expect(mgr.active, isNotNull);
    expect(find.text('Loaded'), findsOneWidget);
    expect(find.text('Unload'), findsOneWidget);
    expect(find.textContaining('Loaded Llama 3.2 3B (test)'), findsOneWidget);
  });

  testWidgets(
    'image and video show Coming Soon and no import action without an importer',
    (tester) async {
      final mgr = (await tester.runAsync(managerWithOneModel))!;
      await tester.pumpWidget(MaterialApp(home: ModelListPage(manager: mgr)));

      expect(find.text('Coming Soon'), findsNWidgets(2));
      expect(find.text('Import GGUF'), findsNothing);
    },
  );
}
