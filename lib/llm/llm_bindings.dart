// Raw Dart FFI bindings for native/include/llm_bridge.h. Keep the two in sync.
// Application code should use LlmEngine (llm_engine.dart), not these directly.
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

typedef ProbeC = Pointer<Utf8> Function();
typedef ProbeDart = Pointer<Utf8> Function();

typedef LoadC =
    Pointer<Void> Function(Pointer<Utf8> modelPath, Int32 nCtx, Int32 nThreads);
typedef LoadDart =
    Pointer<Void> Function(Pointer<Utf8> modelPath, int nCtx, int nThreads);

typedef BeginC =
    Int32 Function(
      Pointer<Void> s,
      Pointer<Utf8> prompt,
      Int32 maxNewTokens,
      Float temperature,
      Uint32 seed,
    );
typedef BeginDart =
    int Function(
      Pointer<Void> s,
      Pointer<Utf8> prompt,
      int maxNewTokens,
      double temperature,
      int seed,
    );

typedef NextC =
    Int32 Function(Pointer<Void> s, Pointer<Uint8> out, Int32 outLen);
typedef NextDart =
    int Function(Pointer<Void> s, Pointer<Uint8> out, int outLen);

typedef StopC = Void Function(Pointer<Void> s);
typedef StopDart = void Function(Pointer<Void> s);

typedef UnloadC = Void Function(Pointer<Void> s);
typedef UnloadDart = void Function(Pointer<Void> s);

typedef SetThreadsC = Int32 Function(Pointer<Void> s, Int32 nThreads);
typedef SetThreadsDart = int Function(Pointer<Void> s, int nThreads);

typedef SuggestThreadsC = Int32 Function();
typedef SuggestThreadsDart = int Function();

typedef GeneratedCountC = Int32 Function(Pointer<Void> s);
typedef GeneratedCountDart = int Function(Pointer<Void> s);

typedef LastErrorC = Pointer<Utf8> Function();
typedef LastErrorDart = Pointer<Utf8> Function();

class LlmBindings {
  LlmBindings._(DynamicLibrary lib)
    : probe = lib.lookupFunction<ProbeC, ProbeDart>('llm_probe'),
      load = lib.lookupFunction<LoadC, LoadDart>('llm_load'),
      begin = lib.lookupFunction<BeginC, BeginDart>('llm_begin'),
      next = lib.lookupFunction<NextC, NextDart>('llm_next'),
      stop = lib.lookupFunction<StopC, StopDart>('llm_stop'),
      unload = lib.lookupFunction<UnloadC, UnloadDart>('llm_unload'),
      setThreads = lib.lookupFunction<SetThreadsC, SetThreadsDart>(
        'llm_set_threads',
      ),
      suggestThreads = lib.lookupFunction<SuggestThreadsC, SuggestThreadsDart>(
        'llm_suggest_threads',
      ),
      generatedCount = lib.lookupFunction<GeneratedCountC, GeneratedCountDart>(
        'llm_generated_count',
      ),
      lastError = lib.lookupFunction<LastErrorC, LastErrorDart>(
        'llm_last_error',
      );

  final ProbeDart probe;
  final LoadDart load;
  final BeginDart begin;
  final NextDart next;
  final StopDart stop;
  final UnloadDart unload;
  final SetThreadsDart setThreads;
  final SuggestThreadsDart suggestThreads;
  final GeneratedCountDart generatedCount;
  final LastErrorDart lastError;

  static LlmBindings? _instance;

  /// Opens libllm_bridge.so once. Only Android is supported (the native build targets arm64-v8a).
  static LlmBindings get instance {
    if (!Platform.isAndroid) {
      throw UnsupportedError('llm_bridge is only built for Android');
    }
    return _instance ??= LlmBindings._(DynamicLibrary.open('libllm_bridge.so'));
  }
}
