import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/chat/chat_store.dart';
import 'package:soft_local_pai/app/app_controller.dart';
import 'package:soft_local_pai/app/soft_local_pai_app.dart';
import 'package:soft_local_pai/models/model_importer.dart';
import 'package:soft_local_pai/models/model_manager.dart';
import 'package:soft_local_pai/models/model_profile.dart';
import 'package:soft_local_pai/search/search_settings_store.dart';

import 'models/fake_runtime.dart';
import 'search/fake_web_search_service.dart';

void main() {
  late Directory root;
  late FakeRuntime runtime;

  setUp(() {
    root = Directory.systemTemp.createTempSync('app_test');
    runtime = FakeRuntime();
  });

  tearDown(() => root.deleteSync(recursive: true));

  var settingsFileCount = 0;

  AppController controllerFor(ModelManager manager) => AppController(
    manager: manager,
    runtime: runtime,
    importer: ModelImporter(),
    store: ChatStore(Directory('${root.path}/chats')),
    suggestedThreads: 4,
    webSearch: FakeWebSearchService(configured: false),
    searchSettingsStore: SearchSettingsStore(
      File('${root.path}/search_settings_${settingsFileCount++}.json'),
    ),
  );

  ModelManager managerFor() => ModelManager(
    rootDir: root,
    runtime: runtime,
    usableRamBytes: () async => 6 * 1024 * 1024 * 1024,
    threads: 4,
  )..init();

  Future<void> addModel(ModelManager manager) async {
    final file = File('${root.path}/models/llama.gguf');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      Uint8List.fromList([...'GGUF'.codeUnits, ...List.filled(64, 0)]),
    );
    await manager.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama 3.2 3B',
      profile: chatProfile,
    );
  }

  testWidgets('splash shows the brand first, with no model installed', (
    tester,
  ) async {
    final manager = managerFor();
    await tester.pumpWidget(
      SoftLocalPaiApp(controller: controllerFor(manager)),
    );

    expect(find.text('SoftDigi AI'), findsOneWidget);
    expect(find.text('Powered by SoftDigi Technology'), findsOneWidget);
    expect(find.text('Import GGUF Model'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('Import GGUF Model'), findsOneWidget);
  });

  testWidgets('no model installed: first-launch screen explains the app', (
    tester,
  ) async {
    final manager = managerFor();
    await tester.pumpWidget(
      SoftLocalPaiApp(controller: controllerFor(manager)),
    );
    await tester.pump(const Duration(milliseconds: 1700));

    expect(find.text('SoftDigi AI'), findsOneWidget);
    expect(
      find.text('SoftDigi AI runs AI directly on your device.'),
      findsOneWidget,
    );
    expect(find.text('Import GGUF Model'), findsOneWidget);
    expect(find.text('Installed Models'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets(
    'with a model installed: main tabs and an empty chat that asks to load a model',
    (tester) async {
      final manager = managerFor();
      await tester.runAsync(() => addModel(manager));
      await tester.pumpWidget(
        SoftLocalPaiApp(controller: controllerFor(manager)),
      );
      await tester.pump(const Duration(milliseconds: 1700));

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Chat'), findsWidgets);
      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Image & Video'), findsOneWidget);
      expect(find.text('Load a model to begin'), findsOneWidget);
      expect(find.text('No model loaded'), findsOneWidget);
    },
  );

  testWidgets('Image & Video tab shows Coming Soon for both', (tester) async {
    final manager = managerFor();
    await tester.runAsync(() => addModel(manager));
    await tester.pumpWidget(
      SoftLocalPaiApp(controller: controllerFor(manager)),
    );
    await tester.pump(const Duration(milliseconds: 1700));

    await tester.tap(find.text('Image & Video'));
    await tester.pumpAndSettle();

    expect(find.text('Coming Soon'), findsNWidgets(2));
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
  });

  testWidgets('Models tab lists the installed model with its use', (
    tester,
  ) async {
    final manager = managerFor();
    await tester.runAsync(() => addModel(manager));
    await tester.pumpWidget(
      SoftLocalPaiApp(controller: controllerFor(manager)),
    );
    await tester.pump(const Duration(milliseconds: 1700));

    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();

    expect(find.text('Llama 3.2 3B'), findsOneWidget);
    expect(find.text('Ready to load'), findsOneWidget);
    expect(find.text('Import GGUF'), findsOneWidget);
  });
}
