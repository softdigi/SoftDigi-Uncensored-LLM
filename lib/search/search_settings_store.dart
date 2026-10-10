import 'dart:convert';
import 'dart:io';

import 'search_mode.dart';

/// Persists the user's chosen [SearchMode] locally, the same atomic
/// write-then-rename way every other local store in this app does. Nothing
/// here ever leaves the device.
class SearchSettingsStore {
  SearchSettingsStore(this.file);

  final File file;

  SearchMode read() {
    if (!file.existsSync()) return SearchMode.smart;
    try {
      final json =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      return searchModeFromName(json['mode'] as String?);
    } catch (_) {
      return SearchMode.smart;
    }
  }

  void write(SearchMode mode) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'mode': mode.name}), flush: true);
    tmp.renameSync(file.path);
  }
}
