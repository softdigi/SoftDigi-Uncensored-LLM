import '../llm/llm_worker.dart';
import '../llm/model_facts.dart';

/// The operations ModelManager needs from the inference engine. The app uses
/// [WorkerModelRuntime]. Tests use a fake.
abstract interface class ModelRuntime {
  Future<ModelFacts> readFacts(String path);

  /// Loads a model and returns the load time in milliseconds. Replaces any loaded model.
  Future<int> load(
    String path, {
    required int contextSize,
    required int threads,
  });

  Future<void> unload();

  Future<int> countTokens(String text);

  Future<void> setThreads(int threads);

  Stream<LlmEvent> generate({
    required String prompt,
    required int maxTokens,
    required double temperature,
    int seed = 1234,
  });

  void stop();
}

/// Runtime backed by the inference worker isolate.
class WorkerModelRuntime implements ModelRuntime {
  WorkerModelRuntime(this.worker);

  final LlmWorker worker;

  @override
  Future<ModelFacts> readFacts(String path) => worker.readModelFacts(path);

  @override
  Future<int> load(
    String path, {
    required int contextSize,
    required int threads,
  }) =>
      worker.load(modelPath: path, contextSize: contextSize, threads: threads);

  @override
  Future<void> unload() => worker.unload();

  @override
  Future<int> countTokens(String text) => worker.countTokens(text);

  @override
  Future<void> setThreads(int threads) => worker.setThreads(threads);

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    required int maxTokens,
    required double temperature,
    int seed = 1234,
  }) => worker.generate(
    prompt: prompt,
    maxTokens: maxTokens,
    temperature: temperature,
    seed: seed,
  );

  @override
  void stop() => worker.stop();
}
