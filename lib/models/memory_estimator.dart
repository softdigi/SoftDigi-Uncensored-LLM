import '../llm/model_facts.dart';

const int kib = 1024;
const int mib = 1024 * kib;
const int gib = 1024 * mib;

/// Estimated resident memory for one model at one context size, in bytes.
class MemoryEstimate {
  const MemoryEstimate({
    required this.weights,
    required this.kvCache,
    required this.compute,
    required this.overhead,
    required this.margin,
  });

  /// Model weights. Memory-mapped, so counted at full file size (an upper bound).
  final int weights;

  /// Key/value cache: 2 (K and V) × layers × KV heads × head dim × context × element size.
  final int kvCache;

  /// Compute buffers: the logits for one micro-batch (ubatch × vocab × 4 bytes)
  /// plus activations for the same micro-batch.
  final int compute;

  /// App runtime: Flutter engine, Dart heap and the inference worker.
  final int overhead;

  /// Safety margin on top of everything else.
  final int margin;

  int get total => weights + kvCache + compute + overhead + margin;
}

/// Planning rules for RAM. The planning limit is the device's physical 8 GB.
/// Android's virtual or extended RAM is never counted.
class MemoryPolicy {
  const MemoryPolicy._();

  /// Physical RAM the app plans against.
  static const int planningRamBytes = 8 * gib;

  /// Largest share of planning RAM a loaded model may use. The rest is for
  /// Android, other apps and Flutter's own growth.
  static const double budgetFraction = 0.60;

  static const int budgetBytes =
      4915 * mib; // ~0.60 × 8 GiB, rounded down to whole MiB

  /// Runtime overhead measured at idle (~280 MB RSS) plus headroom for the worker isolate.
  static const int runtimeOverheadBytes = 384 * mib;

  /// Relative margin added to the estimate for allocator slack and estimation error.
  static const double marginFraction = 0.15;

  /// Micro-batch size used by the native bridge (llm_load sets n_ubatch to 512).
  static const int ubatchTokens = 512;

  /// The llama.cpp KV cache default element size (f16).
  static const int kvElementBytes = 2;

  static const int minContextTokens = 512;
  static const int maxContextCapTokens = 8192;
  static const int contextStepTokens = 256;
}

/// Estimates memory for [facts] at [contextTokens].
MemoryEstimate estimateMemory(ModelFacts facts, int contextTokens) {
  final kv =
      2 *
      facts.nLayer *
      facts.nHeadKv *
      facts.headDim *
      contextTokens *
      MemoryPolicy.kvElementBytes;
  final logits = MemoryPolicy.ubatchTokens * facts.nVocab * 4;
  final activations = MemoryPolicy.ubatchTokens * facts.nEmbd * 4 * 4;
  final subtotal =
      facts.sizeBytes +
      kv +
      logits +
      activations +
      MemoryPolicy.runtimeOverheadBytes;
  return MemoryEstimate(
    weights: facts.sizeBytes,
    kvCache: kv,
    compute: logits + activations,
    overhead: MemoryPolicy.runtimeOverheadBytes,
    margin: (subtotal * MemoryPolicy.marginFraction).ceil(),
  );
}

/// Largest context (in tokens) that fits the budget, or null if even the minimum does not.
///
/// The result is limited by the model's trained context and [MemoryPolicy.maxContextCapTokens],
/// and is a multiple of [MemoryPolicy.contextStepTokens].
int? maxContextFor(
  ModelFacts facts, {
  int budgetBytes = MemoryPolicy.budgetBytes,
}) {
  final ceiling = facts.nCtxTrain < MemoryPolicy.maxContextCapTokens
      ? facts.nCtxTrain
      : MemoryPolicy.maxContextCapTokens;
  if (estimateMemory(facts, MemoryPolicy.minContextTokens).total >
      budgetBytes) {
    return null;
  }
  if (ceiling < MemoryPolicy.minContextTokens) return ceiling;
  // Binary search over steps of contextStepTokens. Memory grows with context.
  var lo = MemoryPolicy.minContextTokens ~/ MemoryPolicy.contextStepTokens;
  var hi = ceiling ~/ MemoryPolicy.contextStepTokens;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    final fits =
        estimateMemory(facts, mid * MemoryPolicy.contextStepTokens).total <=
        budgetBytes;
    if (fits) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo * MemoryPolicy.contextStepTokens;
}
