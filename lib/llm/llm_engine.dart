import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'llm_bindings.dart';

/// Thrown when the native bridge reports an error.
class LlmException implements Exception {
  const LlmException(this.message);

  final String message;

  @override
  String toString() => 'LlmException: $message';
}

/// One loaded GGUF model with a single generation context.
///
/// Not thread-safe. Own it from exactly one isolate. In the app that is the
/// inference worker (llm_worker.dart); the UI isolate never touches it.
class LlmEngine {
  LlmEngine._(this._session);

  static const int _pieceBufferSize = 512;
  static const int _contextFullCode = -8;

  final Pointer<Void> _session;
  bool _disposed = false;

  // Reused for every llm_next call. Freed in dispose().
  final Pointer<Uint8> _pieceBuffer = malloc<Uint8>(_pieceBufferSize);
  final Utf8ChunkDecoder _decoder = Utf8ChunkDecoder();

  /// Loads a GGUF file. [threads] <= 0 uses [suggestThreads].
  static LlmEngine load({
    required String modelPath,
    int contextSize = 2048,
    int threads = 0,
  }) {
    final bindings = LlmBindings.instance;
    final pathPtr = modelPath.toNativeUtf8();
    try {
      final session = bindings.load(pathPtr, contextSize, threads);
      if (session == nullptr) {
        throw LlmException(_lastError(bindings));
      }
      return LlmEngine._(session);
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Performance-core count for this device, capped at 4.
  static int suggestThreads() => LlmBindings.instance.suggestThreads();

  void setThreads(int threads) {
    _ensureOpen();
    _check(LlmBindings.instance.setThreads(_session, threads));
  }

  /// Prefills [prompt] and prepares sampling. [prompt] must be built by
  /// buildLlama3Prompt, which escapes control tokens in user text.
  /// Returns the prefill time in microseconds.
  int begin({
    required String prompt,
    required int maxTokens,
    double temperature = 0.7,
    int seed = 1234,
  }) {
    _ensureOpen();
    final bindings = LlmBindings.instance;
    final promptPtr = prompt.toNativeUtf8();
    final sw = Stopwatch()..start();
    try {
      _check(bindings.begin(_session, promptPtr, maxTokens, temperature, seed));
    } finally {
      malloc.free(promptPtr);
    }
    _decoder.close();
    return sw.elapsedMicroseconds;
  }

  /// Samples the next token. Returns the text it adds (possibly empty), or
  /// null at end of generation (end-of-turn, max tokens, or [stop]).
  String? nextChunk() {
    _ensureOpen();
    final bindings = LlmBindings.instance;
    final n = bindings.next(_session, _pieceBuffer, _pieceBufferSize);
    if (n < 0) {
      if (n == _contextFullCode) {
        throw const LlmException(
          'context window is full; start a new conversation or raise the context size',
        );
      }
      throw LlmException(_lastError(bindings));
    }
    if (n == 0) {
      final tail = _decoder.close();
      return tail.isEmpty ? null : tail;
    }
    return _decoder.add(_pieceBuffer.asTypedList(n));
  }

  /// Tokens sampled since the last [begin], including ones with empty text.
  int get generatedTokens {
    _ensureOpen();
    return LlmBindings.instance.generatedCount(_session);
  }

  /// Asks the current generation to stop. Takes effect before the next token.
  /// Safe to call from another isolate, because it only sets a native atomic flag.
  void stop() {
    _ensureOpen();
    LlmBindings.instance.stop(_session);
  }

  /// Frees the model and context. The engine cannot be used afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    LlmBindings.instance.unload(_session);
    malloc.free(_pieceBuffer);
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('LlmEngine has been disposed');
  }

  void _check(int code) {
    if (code != 0) {
      throw LlmException(_lastError(LlmBindings.instance));
    }
  }

  static String _lastError(LlmBindings bindings) {
    final ptr = bindings.lastError();
    return ptr == nullptr ? 'unknown error' : ptr.toDartString();
  }
}

/// Decodes UTF-8 that arrives in arbitrary byte chunks.
///
/// A token's bytes can end in the middle of a multi-byte character. The
/// incomplete tail is held back until the next chunk completes it.
class Utf8ChunkDecoder {
  final List<int> _pending = <int>[];

  /// Returns the text that is complete so far.
  String add(Uint8List chunk) {
    _pending.addAll(chunk);
    final cut = _completeLength(_pending);
    if (cut == 0) return '';
    final text = utf8.decode(_pending.sublist(0, cut), allowMalformed: true);
    _pending.removeRange(0, cut);
    return text;
  }

  /// Flushes any held bytes, replacing an incomplete sequence with U+FFFD.
  String close() {
    if (_pending.isEmpty) return '';
    final text = utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    return text;
  }

  static int _completeLength(List<int> bytes) {
    // Find the lead byte of the last character. Continuation bytes are 10xxxxxx.
    var i = bytes.length - 1;
    var continuation = 0;
    while (i >= 0 && continuation < 3 && (bytes[i] & 0xC0) == 0x80) {
      i--;
      continuation++;
    }
    if (i < 0) return bytes.length;

    final lead = bytes[i];
    final int needed;
    if (lead < 0x80) {
      needed = 1;
    } else if ((lead & 0xE0) == 0xC0) {
      needed = 2;
    } else if ((lead & 0xF0) == 0xE0) {
      needed = 3;
    } else if ((lead & 0xF8) == 0xF0) {
      needed = 4;
    } else {
      needed = 1;
    }
    final have = bytes.length - i;
    return have >= needed ? bytes.length : i;
  }
}
