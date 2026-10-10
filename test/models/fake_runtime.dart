import 'dart:async';

import 'package:soft_local_pai/llm/llm_worker.dart';
import 'package:soft_local_pai/llm/model_facts.dart';
import 'package:soft_local_pai/models/model_runtime.dart';

/// Llama 3.2 3B Instruct Q4_K_M, as read from the real GGUF on the device.
const ModelFacts llama32_3bFacts = ModelFacts(
  arch: 'llama',
  nLayer: 28,
  nHead: 24,
  nHeadKv: 8,
  nEmbd: 3072,
  headDim: 128,
  nCtxTrain: 131072,
  nVocab: 128256,
  sizeBytes: 2019377696,
);

class FakeRuntime implements ModelRuntime {
  ModelFacts facts = llama32_3bFacts;
  final List<String> calls = [];
  String? loadedPath;
  int? loadedContext;
  bool failLoad = false;
  int countPerCharDivisor = 4;

  /// The exact prompt text the last [generate] call received, for tests that
  /// need to see what actually reached the model.
  String? lastPrompt;

  @override
  Future<ModelFacts> readFacts(String path) async {
    calls.add('readFacts');
    return facts;
  }

  @override
  Future<int> load(
    String path, {
    required int contextSize,
    required int threads,
  }) async {
    calls.add('load');
    if (failLoad) throw StateError('boom');
    loadedPath = path;
    loadedContext = contextSize;
    return 5;
  }

  @override
  Future<void> unload() async {
    calls.add('unload');
    loadedPath = null;
  }

  @override
  Future<int> countTokens(String text) async =>
      text.length ~/ countPerCharDivisor;

  @override
  Future<void> setThreads(int threads) async {}

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    required int maxTokens,
    required double temperature,
    int seed = 1234,
  }) async* {
    calls.add('generate');
    lastPrompt = prompt;
    yield const LlmToken('hi');
    yield const LlmDone(
      GenerationStats(
        prefillMs: 1,
        tokens: 1,
        decodeMs: 1,
        end: GenerationEnd.endOfTurn,
      ),
    );
  }

  @override
  void stop() {}
}
