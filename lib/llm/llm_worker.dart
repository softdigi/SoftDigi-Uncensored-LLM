// Long-lived inference isolate. It owns the single native model/session, so
// the UI isolate never blocks on llama.cpp.
//
// Main isolate  --commands-->  worker isolate (LlmEngine, FFI calls)
// Main isolate  <--events----  worker isolate
//
// Only one model is loaded at a time. Loading another model unloads the
// current one first. Only one generation runs at a time.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'llm_engine.dart';
import 'model_facts.dart';

/// Why a generation finished.
enum GenerationEnd { endOfTurn, maxTokens, stopped }

/// Timing for one finished generation. Times are measured in the worker.
class GenerationStats {
  const GenerationStats({
    required this.prefillMs,
    required this.tokens,
    required this.decodeMs,
    required this.end,
  });

  /// Time to tokenize and evaluate the prompt.
  final int prefillMs;

  /// Tokens sampled, including ones whose text is empty.
  final int tokens;

  /// Time spent sampling and decoding the generated tokens.
  final int decodeMs;

  final GenerationEnd end;

  double get tokensPerSecond => decodeMs == 0 ? 0 : tokens * 1000 / decodeMs;

  @override
  String toString() =>
      'prefill ${prefillMs}ms, $tokens tokens in ${decodeMs}ms '
      '(${tokensPerSecond.toStringAsFixed(2)} tok/s), end=${end.name}';
}

/// Events for one generation request.
sealed class LlmEvent {
  const LlmEvent();
}

final class LlmToken extends LlmEvent {
  const LlmToken(this.text);

  final String text;
}

final class LlmDone extends LlmEvent {
  const LlmDone(this.stats);

  final GenerationStats stats;
}

/// Thrown into the generation stream when the worker reports an error.
class LlmWorkerException implements Exception {
  const LlmWorkerException(this.message);

  final String message;

  @override
  String toString() => 'LlmWorkerException: $message';
}

/// Main-isolate handle to the inference worker.
class LlmWorker {
  LlmWorker._(this._isolate, this._toWorker, this._fromWorker);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;

  int _nextId = 1;
  final Map<int, Completer<Map<Object?, Object?>>> _requests = {};
  final Map<int, StreamController<LlmEvent>> _generations = {};
  int? _activeGenerationId;
  bool _disposed = false;

  /// Starts the worker isolate. It does not load a model.
  static Future<LlmWorker> spawn() async {
    final fromWorker = ReceivePort();
    final ready = Completer<SendPort>();
    late final LlmWorker worker;

    // The first message is the worker's command port. Every later message is a reply or event.
    fromWorker.listen((message) {
      if (!ready.isCompleted) {
        ready.complete(message as SendPort);
      } else {
        worker._onMessage(message);
      }
    });

    final isolate = await Isolate.spawn(
      _workerMain,
      fromWorker.sendPort,
      debugName: 'llm-worker',
    );
    final toWorker = await ready.future;
    worker = LlmWorker._(isolate, toWorker, fromWorker);
    return worker;
  }

  bool get isGenerating => _activeGenerationId != null;

  /// Loads [modelPath], unloading any model already loaded.
  /// Returns the load time in milliseconds.
  Future<int> load({
    required String modelPath,
    int contextSize = 2048,
    int threads = 0,
  }) async {
    final reply = await _request({
      'cmd': 'load',
      'path': modelPath,
      'ctx': contextSize,
      'threads': threads,
    });
    return reply['loadMs'] as int;
  }

  /// Starts a generation. Events arrive as [LlmToken]s, then one [LlmDone].
  /// Failures arrive as an [LlmWorkerException] error on the stream.
  Stream<LlmEvent> generate({
    required String prompt,
    int maxTokens = 256,
    double temperature = 0.7,
    int seed = 1234,
  }) {
    _ensureOpen();
    if (isGenerating) {
      throw StateError('a generation is already running');
    }
    final id = _nextId++;
    final controller = StreamController<LlmEvent>();
    _generations[id] = controller;
    _activeGenerationId = id;
    _toWorker.send({
      'cmd': 'generate',
      'id': id,
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'seed': seed,
    });
    return controller.stream;
  }

  /// Stops the running generation. It ends with an [LlmDone] whose end is [GenerationEnd.stopped].
  void stop() {
    _ensureOpen();
    final id = _activeGenerationId;
    if (id == null) return;
    _toWorker.send({'cmd': 'stop', 'id': id});
  }

  /// Frees the model. Any running generation is stopped first.
  Future<void> unload() async {
    await _request({'cmd': 'unload'});
  }

  /// Reads model metadata without loading weights. Safe to call while another model is loaded.
  Future<ModelFacts> readModelFacts(String path) async {
    final reply = await _request({'cmd': 'info', 'path': path});
    return ModelFacts.fromJson((reply['facts'] as Map).cast<String, Object?>());
  }

  /// Token count of [text] under the loaded model's tokenizer.
  Future<int> countTokens(String text) async {
    final reply = await _request({'cmd': 'count', 'text': text});
    return reply['tokens'] as int;
  }

  /// Thread count suggested for this device. Asked of the worker so the UI isolate never calls FFI.
  Future<int> suggestThreads() async {
    final reply = await _request({'cmd': 'suggest'});
    return reply['threads'] as int;
  }

  Future<void> setThreads(int threads) async {
    await _request({'cmd': 'threads', 'n': threads});
  }

  /// Unloads the model and stops the worker isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    await unload();
    _disposed = true;
    _toWorker.send({'cmd': 'exit'});
    _isolate.kill(priority: Isolate.immediate);
    _fromWorker.close();
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('LlmWorker has been disposed');
  }

  Future<Map<Object?, Object?>> _request(Map<String, Object?> command) {
    _ensureOpen();
    final id = _nextId++;
    final completer = Completer<Map<Object?, Object?>>();
    _requests[id] = completer;
    _toWorker.send({...command, 'id': id});
    return completer.future;
  }

  void _onMessage(Object? raw) {
    final msg = raw as Map<Object?, Object?>;
    final id = msg['id'] as int;
    switch (msg['type']) {
      case 'ok':
        _requests.remove(id)?.complete(msg);
      case 'error':
        final text = msg['message'] as String;
        final request = _requests.remove(id);
        if (request != null) {
          request.completeError(LlmWorkerException(text));
          return;
        }
        final controller = _generations.remove(id);
        if (_activeGenerationId == id) _activeGenerationId = null;
        controller?.addError(LlmWorkerException(text));
        controller?.close();
      case 'token':
        _generations[id]?.add(LlmToken(msg['text'] as String));
      case 'done':
        final stats = GenerationStats(
          prefillMs: msg['prefillMs'] as int,
          tokens: msg['tokens'] as int,
          decodeMs: msg['decodeMs'] as int,
          end: GenerationEnd.values.byName(msg['end'] as String),
        );
        final controller = _generations.remove(id);
        if (_activeGenerationId == id) _activeGenerationId = null;
        controller?.add(LlmDone(stats));
        controller?.close();
    }
  }
}

// ---------------------------------------------------------------------------
// Worker isolate side. Nothing below may run on the UI isolate.
// ---------------------------------------------------------------------------

void _workerMain(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  final worker = _WorkerState(toMain);
  inbox.listen((raw) {
    final msg = raw as Map<Object?, Object?>;
    if (msg['cmd'] == 'exit') {
      worker.shutdown();
      inbox.close();
      return;
    }
    worker.handle(msg);
  });
}

class _ActiveGeneration {
  _ActiveGeneration(this.id);

  final int id;
  bool stopRequested = false;
  final Completer<void> finished = Completer<void>();
}

class _WorkerState {
  _WorkerState(this._toMain);

  final SendPort _toMain;
  LlmEngine? _engine;
  _ActiveGeneration? _active;

  void handle(Map<Object?, Object?> msg) {
    final id = msg['id'] as int;
    final cmd = msg['cmd'] as String;
    try {
      switch (cmd) {
        case 'load':
          _load(msg, id);
        case 'generate':
          _generate(msg, id); // runs asynchronously; errors are reported inside
        case 'stop':
          _stop(msg['id'] as int);
        case 'unload':
          _unloadThen(id);
        case 'info':
          final facts = LlmEngine.readModelFacts(msg['path'] as String);
          _toMain.send({'type': 'ok', 'id': id, 'facts': facts.toJson()});
        case 'suggest':
          _toMain.send({
            'type': 'ok',
            'id': id,
            'threads': LlmEngine.suggestThreads(),
          });
        case 'count':
          final engine = _engine;
          if (engine == null) {
            _error(id, 'no model loaded');
          } else {
            _toMain.send({
              'type': 'ok',
              'id': id,
              'tokens': engine.countTokens(msg['text'] as String),
            });
          }
        case 'threads':
          _engine?.setThreads(msg['n'] as int);
          _ok(id);
        default:
          _error(id, 'unknown command $cmd');
      }
    } catch (e) {
      _error(id, e.toString());
    }
  }

  void _load(Map<Object?, Object?> msg, int id) {
    if (_active != null) {
      _error(id, 'stop the running generation before loading a model');
      return;
    }
    final sw = Stopwatch()..start();
    // Only one model may be resident. Unload the old one before loading the new one.
    _releaseEngine();
    _engine = LlmEngine.load(
      modelPath: msg['path'] as String,
      contextSize: msg['ctx'] as int,
      threads: msg['threads'] as int,
    );
    _toMain.send({'type': 'ok', 'id': id, 'loadMs': sw.elapsedMilliseconds});
  }

  Future<void> _generate(Map<Object?, Object?> msg, int id) async {
    final engine = _engine;
    if (engine == null) {
      _error(id, 'no model loaded');
      return;
    }
    if (_active != null) {
      _error(id, 'a generation is already running');
      return;
    }
    final maxTokens = msg['maxTokens'] as int;
    final active = _ActiveGeneration(id);
    _active = active;
    try {
      final prefillUs = engine.begin(
        prompt: msg['prompt'] as String,
        maxTokens: maxTokens,
        temperature: msg['temperature'] as double,
        seed: msg['seed'] as int,
      );
      final decode = Stopwatch()..start();
      while (!active.stopRequested) {
        final text = engine.nextChunk();
        if (text == null) break;
        if (text.isNotEmpty) {
          _toMain.send({'type': 'token', 'id': id, 'text': text});
        }
        // Let queued commands (stop, unload) run between tokens.
        await Future<void>.delayed(Duration.zero);
      }
      final tokens = engine.generatedTokens;
      final GenerationEnd end;
      if (active.stopRequested) {
        end = GenerationEnd.stopped;
      } else if (tokens >= maxTokens) {
        end = GenerationEnd.maxTokens;
      } else {
        end = GenerationEnd.endOfTurn;
      }
      _toMain.send({
        'type': 'done',
        'id': id,
        'prefillMs': prefillUs ~/ 1000,
        'tokens': tokens,
        'decodeMs': decode.elapsedMilliseconds,
        'end': end.name,
      });
    } catch (e) {
      _error(id, e.toString());
    } finally {
      _active = null;
      active.finished.complete();
    }
  }

  void _stop(int id) {
    final active = _active;
    if (active == null || active.id != id) return;
    active.stopRequested = true;
    _engine?.stop();
  }

  /// Stops any running generation, then frees the model.
  Future<void> _unloadThen(int id) async {
    final active = _active;
    if (active != null) {
      active.stopRequested = true;
      _engine?.stop();
      await active.finished.future;
    }
    _releaseEngine();
    _ok(id);
  }

  void _releaseEngine() {
    _engine?.dispose();
    _engine = null;
  }

  void shutdown() {
    _active?.stopRequested = true;
    _engine?.stop();
    _releaseEngine();
  }

  void _ok(int id) => _toMain.send({'type': 'ok', 'id': id});

  void _error(int id, String message) =>
      _toMain.send({'type': 'error', 'id': id, 'message': message});
}

/// Resident set size of this process in MB, or -1 if unavailable.
/// Works on Android (reads /proc/self/status). Call it from any isolate.
int processRssMb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmRSS:')) {
        final kb = int.parse(line.replaceAll(RegExp(r'[^0-9]'), ''));
        return kb ~/ 1024;
      }
    }
  } catch (_) {
    // Not available on this platform.
  }
  return -1;
}
