import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/models/model_registry.dart';

import 'fake_runtime.dart';

void main() {
  test('writes and reads back every field, including quarantine', () {
    final dir = Directory.systemTemp.createTempSync('reg_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ModelRegistryStore(File('${dir.path}/registry.json'));
    final model = InstalledModel(
      id: 'm1',
      profileId: 'chat-llama32-3b-q4km',
      displayName: 'Llama',
      fileName: 'llama.gguf',
      sizeBytes: 2019377696,
      importedAt: DateTime.utc(2026, 10, 6, 12),
      facts: llama32_3bFacts,
      quarantineReason: 'loading did not finish',
    );
    store.write([model]);
    final back = store.read().single;
    expect(back.id, 'm1');
    expect(back.facts.nVocab, 128256);
    expect(back.importedAt, DateTime.utc(2026, 10, 6, 12));
    expect(back.isQuarantined, isTrue);
    expect(File('${dir.path}/registry.json.tmp').existsSync(), isFalse);
  });

  test('a missing registry reads as empty', () {
    final dir = Directory.systemTemp.createTempSync('reg_test2');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(
      ModelRegistryStore(File('${dir.path}/registry.json')).read(),
      isEmpty,
    );
  });
}
