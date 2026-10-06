import 'package:flutter/services.dart';

/// A GGUF file the user picked and the native side copied into the app's
/// private models folder. The file is not yet registered or validated beyond its magic bytes.
class PickedGguf {
  const PickedGguf({
    required this.fileName,
    required this.displayName,
    required this.sizeBytes,
  });

  final String fileName;
  final String displayName;
  final int sizeBytes;
}

/// Bridges Android's file picker (Storage Access Framework) and private storage.
class ModelImporter {
  static const MethodChannel _import = MethodChannel('softlocalpai/import');
  static const MethodChannel _paths = MethodChannel('softlocalpai/paths');
  static const MethodChannel _thermal = MethodChannel('softlocalpai/thermal');

  /// Opens the system file picker and copies the chosen file into private storage.
  /// Returns null if the user cancels. Throws PlatformException with code
  /// `bad_header` if the file is not a GGUF.
  Future<PickedGguf?> pickAndCopy() async {
    final reply = await _import.invokeMapMethod<String, Object?>('pickGguf');
    if (reply == null) return null;
    return PickedGguf(
      fileName: reply['fileName'] as String,
      displayName: reply['displayName'] as String,
      sizeBytes: reply['sizeBytes'] as int,
    );
  }

  /// The app's private files directory (internal storage, not shared).
  Future<String> privateFilesDir() async {
    final dir = await _paths.invokeMethod<String>('filesDir');
    if (dir == null) throw StateError('private files directory unavailable');
    return dir;
  }

  /// Thermal status code (0 = none ... 6 = shutdown). Returns 0 if unavailable.
  Future<int> thermalStatusCode() async {
    try {
      return await _thermal.invokeMethod<int>('status') ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }
}
