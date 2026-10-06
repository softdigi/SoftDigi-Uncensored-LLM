import 'dart:io';

/// Records which model is being loaded. If the process dies during the load,
/// the marker is still there on the next start, and that model is quarantined.
/// This stops a model that crashes the process from being loaded again at startup.
class CrashMarker {
  CrashMarker(this.file);

  final File file;

  /// Writes the marker before a load starts. Flushed so it survives a crash.
  void begin(String modelId) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(modelId, flush: true);
  }

  /// Removes the marker after a load finishes, successfully or with an error.
  void end() {
    if (file.existsSync()) file.deleteSync();
  }

  /// Returns the model id left by a previous process that died during a load,
  /// and removes the marker. Returns null if the last load finished.
  String? takeStale() {
    if (!file.existsSync()) return null;
    final id = file.readAsStringSync().trim();
    file.deleteSync();
    return id.isEmpty ? null : id;
  }
}
