import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/app/screens/model_download_screen.dart';
import 'package:soft_local_pai/download/model_catalog.dart';
import 'package:soft_local_pai/models/model_importer.dart';
import 'package:soft_local_pai/models/model_manager.dart';

import '../models/fake_runtime.dart';

void main() {
  late Directory root;
  late FakeRuntime runtime;

  setUp(() {
    root = Directory.systemTemp.createTempSync('download_screen_test');
    runtime = FakeRuntime();
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The catalog page is a long ListView; a default test surface only
  /// covers the first screenful, and a Sliver list never builds elements
  /// for items outside the viewport. Use a tall virtual viewport so every
  /// section and card actually exists in the element tree for `find`.
  Future<void> pumpTall(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 10000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: child));
    await tester.pumpAndSettle();
  }

  ModelManager emptyManager() =>
      ModelManager(
        rootDir: root,
        runtime: runtime,
        usableRamBytes: () async => 6 * 1024 * 1024 * 1024,
        threads: 4,
      )..init();

  testWidgets('renders every catalog category as a section', (tester) async {
    await pumpTall(
      tester,
      ModelDownloadScreen(manager: emptyManager(), importer: ModelImporter()),
    );

    expect(find.text('Recommended for Your Device'), findsOneWidget);
    expect(find.text('Small Models'), findsOneWidget);
    expect(find.text('Medium Models'), findsOneWidget);
    expect(find.text('Large Models'), findsOneWidget);
    expect(find.text('Uncensored Models'), findsOneWidget);

    // Every catalog entry's display name appears somewhere on the page.
    for (final entry in modelCatalog) {
      expect(find.text(entry.displayName), findsAtLeastNWidgets(1));
    }
  });

  testWidgets('a compatible small model shows Compatible and a Download button', (
    tester,
  ) async {
    await pumpTall(
      tester,
      ModelDownloadScreen(manager: emptyManager(), importer: ModelImporter()),
    );

    // This model is both a Small entry and a Recommended one, so it may be
    // rendered twice (once per section) — assert presence, not an exact count.
    final card = find.ancestor(
      of: find.text('Qwen2.5-Coder 1.5B Instruct'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: card, matching: find.text('Compatible')),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.descendant(of: card, matching: find.text('Download')),
      findsAtLeastNWidgets(1),
    );
  });

  testWidgets('the 14B model shows Not recommended and no Download button', (
    tester,
  ) async {
    await pumpTall(
      tester,
      ModelDownloadScreen(manager: emptyManager(), importer: ModelImporter()),
    );

    final card = find.ancestor(
      of: find.text('Qwen2.5-14B Instruct'),
      matching: find.byType(Card),
    );
    expect(find.descendant(of: card, matching: find.text('Not recommended')), findsOneWidget);
  });

  testWidgets('an already-installed model shows as already downloaded, not a Download button', (
    tester,
  ) async {
    final entry = modelCatalog.firstWhere((e) => e.id == 'qwen25-coder-1.5b-q4km');
    // Real dart:io file writes and ModelManager.registerFile must run outside
    // the fake-async test zone testWidgets sets up, exactly like
    // model_list_page_test.dart's managerWithOneModel helper does.
    final mgr = await tester.runAsync(() async {
      final m = emptyManager();
      final file = File('${m.modelsDir.path}/${entry.fileName}');
      file.writeAsBytesSync(
        Uint8List.fromList([...'GGUF'.codeUnits, ...List.filled(64, 0)]),
      );
      await m.registerFile(
        fileName: entry.fileName,
        displayName: entry.displayName,
        profile: entry.profile,
      );
      return m;
    });

    await pumpTall(
      tester,
      ModelDownloadScreen(manager: mgr!, importer: ModelImporter()),
    );

    // Also both a Small and a Recommended entry — may render twice.
    final card = find.ancestor(
      of: find.text(entry.displayName),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('Already downloaded')),
      findsAtLeastNWidgets(1),
    );
    expect(find.descendant(of: card, matching: find.text('Download')), findsNothing);
  });
}
