import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/search/search_mode.dart';
import 'package:soft_local_pai/search/search_settings_store.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('search_settings'));
  tearDown(() => root.deleteSync(recursive: true));

  test('defaults to Smart mode when nothing has been saved yet', () {
    final store = SearchSettingsStore(File('${root.path}/settings.json'));
    expect(store.read(), SearchMode.smart);
  });

  test('round-trips a written mode', () {
    final store = SearchSettingsStore(File('${root.path}/settings.json'));
    store.write(SearchMode.localOnly);
    expect(store.read(), SearchMode.localOnly);

    store.write(SearchMode.webSearchAllowed);
    expect(store.read(), SearchMode.webSearchAllowed);
  });

  test('a damaged settings file falls back to Smart mode', () {
    final file = File('${root.path}/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('not json');
    final store = SearchSettingsStore(file);
    expect(store.read(), SearchMode.smart);
  });
}
