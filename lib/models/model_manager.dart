import 'dart:io';
import 'dart:math';

import '../llm/model_facts.dart';
import 'crash_marker.dart';
import 'memory_estimator.dart';
import 'memory_gate.dart';
import 'model_profile.dart';
import 'model_registry.dart';
import 'model_runtime.dart';

class ModelManagerException implements Exception {
  const ModelManagerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of loading a model: the context used and the memory estimate.
class ActivationReport {
  const ActivationReport({
    required this.model,
    required this.contextTokens,
    required this.contextClamped,
    required this.estimate,
    required this.loadMs,
  });

  final InstalledModel model;
  final int contextTokens;

  /// True when the requested context was reduced to fit the memory budget.
  final bool contextClamped;
  final MemoryEstimate estimate;
  final int loadMs;
}

/// Owns the set of GGUF models in the app's private storage, and which one is loaded.
///
/// Layout under [rootDir]:
///   models/registry.json      metadata for every model
///   models/`<name>`.gguf      model files
///   models/loading.marker     present only while a load is in progress
///
/// Only one model is loaded at a time. Activating another model unloads the current one first.
class ModelManager {
  ModelManager({
    required this.rootDir,
    required this.runtime,
    required this.usableRamBytes,
    required this.threads,
  }) : marker = CrashMarker(File('${rootDir.path}/models/loading.marker')),
       _registry = ModelRegistryStore(
         File('${rootDir.path}/models/registry.json'),
       );

  final Directory rootDir;
  final ModelRuntime runtime;

  /// Returns the RAM the system reports as available right now, in bytes.
  final Future<int> Function() usableRamBytes;

  /// Generation thread count to request when loading.
  final int threads;

  final CrashMarker marker;
  final ModelRegistryStore _registry;

  List<InstalledModel> _models = [];
  InstalledModel? _active;
  int? _activeContext;

  /// Notes from startup recovery, for display.
  final List<String> recoveryNotes = [];

  Directory get modelsDir => Directory('${rootDir.path}/models');

  List<InstalledModel> get models => List.unmodifiable(_models);

  InstalledModel? get active => _active;

  int? get activeContextTokens => _activeContext;

  InstalledModel? byId(String id) {
    for (final m in _models) {
      if (m.id == id) return m;
    }
    return null;
  }

  File fileFor(InstalledModel model) =>
      File('${modelsDir.path}/${model.fileName}');

  /// Creates the folder, loads the registry, and recovers from an interrupted load.
  /// Models whose file is missing are removed from the registry.
  void init() {
    modelsDir.createSync(recursive: true);
    _models = _registry.read();

    final stale = marker.takeStale();
    if (stale != null) {
      final i = _models.indexWhere((m) => m.id == stale);
      if (i >= 0) {
        _models[i] = _models[i].copyWith(
          quarantineReason:
              'loading did not finish last time (app stopped or crashed)',
        );
        recoveryNotes.add(
          '${_models[i].displayName}: quarantined after an interrupted load',
        );
      }
    }

    final kept = <InstalledModel>[];
    for (final m in _models) {
      if (fileFor(m).existsSync()) {
        kept.add(m);
      } else {
        recoveryNotes.add('${m.displayName}: file missing, entry removed');
      }
    }
    _models = kept;
    _registry.write(_models);
  }

  /// Registers a GGUF file that is already in [modelsDir].
  /// Checks the GGUF magic, then reads the metadata through the runtime.
  /// On failure the file is deleted.
  Future<InstalledModel> registerFile({
    required String fileName,
    required String displayName,
    required ModelProfile profile,
  }) async {
    final file = File('${modelsDir.path}/$fileName');
    if (!file.existsSync()) {
      throw ModelManagerException('file not found in models folder: $fileName');
    }
    if (!await hasGgufMagic(file)) {
      file.deleteSync();
      throw const ModelManagerException(
        'not a GGUF file (bad header); file removed',
      );
    }
    final ModelFacts facts;
    try {
      facts = await runtime.readFacts(file.path);
    } catch (e) {
      file.deleteSync();
      throw ModelManagerException(
        'GGUF metadata could not be read; file removed ($e)',
      );
    }
    final model = InstalledModel(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      profileId: profile.id,
      displayName: displayName,
      fileName: fileName,
      sizeBytes: file.lengthSync(),
      importedAt: DateTime.now(),
      facts: facts,
    );
    _models = [..._models, model];
    _registry.write(_models);
    return model;
  }

  /// Removes a model and its file. Unloads it first if it is active.
  Future<void> delete(String id) async {
    final model = byId(id);
    if (model == null) return;
    if (_active?.id == id) await deactivate();
    final file = fileFor(model);
    if (file.existsSync()) file.deleteSync();
    _models = _models.where((m) => m.id != id).toList();
    _registry.write(_models);
  }

  /// Clears a quarantine after the user has chosen to try the model again.
  void clearQuarantine(String id) {
    final i = _models.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _models[i] = _models[i].copyWith(clearQuarantine: true);
    _registry.write(_models);
  }

  /// Loads [id] with the context the memory budget allows.
  ///
  /// Refuses when the model is quarantined, when even the minimum context does
  /// not fit the budget, or when the device has too little free RAM right now.
  /// Replaces the active model (switching).
  Future<ActivationReport> activate(
    String id, {
    required ModelProfile profile,
    int? requestedContext,
  }) async {
    final model = byId(id);
    if (model == null) throw const ModelManagerException('model not found');
    if (model.isQuarantined) {
      throw ModelManagerException(
        '${model.displayName} is quarantined: ${model.quarantineReason}. Clear it to retry.',
      );
    }

    final maxCtx = maxContextFor(model.facts);
    if (maxCtx == null) {
      throw ModelManagerException(
        '${model.displayName} does not fit the ${MemoryPolicy.budgetBytes ~/ mib} MiB budget '
        'even at ${MemoryPolicy.minContextTokens} tokens',
      );
    }
    final wanted = requestedContext ?? profile.defaultContext;
    final context = min(max(wanted, MemoryPolicy.minContextTokens), maxCtx);
    final estimate = estimateMemory(model.facts, context);

    final gate = MemoryGate.check(
      usableBytes: await usableRamBytes(),
      estimate: estimate,
    );
    if (!gate.allowed) {
      throw ModelManagerException(gate.userMessage);
    }

    if (_active != null) {
      await deactivate();
    }

    // A failed load is recorded as an error. A load that dies with the process
    // leaves the marker, so next start quarantines the model.
    marker.begin(model.id);
    final int loadMs;
    try {
      loadMs = await runtime.load(
        fileFor(model).path,
        contextSize: context,
        threads: threads,
      );
    } catch (e) {
      marker.end();
      throw ModelManagerException('load failed: $e');
    }
    marker.end();

    _active = model;
    _activeContext = context;
    return ActivationReport(
      model: model,
      contextTokens: context,
      contextClamped: context < wanted,
      estimate: estimate,
      loadMs: loadMs,
    );
  }

  /// Unloads the active model, if any.
  Future<void> deactivate() async {
    if (_active == null) return;
    await runtime.unload();
    _active = null;
    _activeContext = null;
  }

  /// True if [file] begins with the GGUF magic bytes "GGUF".
  static Future<bool> hasGgufMagic(File file) async {
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      return head.length == 4 &&
          head[0] == 0x47 &&
          head[1] == 0x47 &&
          head[2] == 0x55 &&
          head[3] == 0x46;
    } finally {
      await raf.close();
    }
  }
}
