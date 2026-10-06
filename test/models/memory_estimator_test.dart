import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/llm/model_facts.dart';
import 'package:soft_local_pai/models/memory_estimator.dart';

import 'fake_runtime.dart';

void main() {
  test('KV cache follows 2 x layers x KV heads x head dim x ctx x 2 bytes', () {
    final e = estimateMemory(llama32_3bFacts, 2048);
    expect(e.kvCache, 2 * 28 * 8 * 128 * 2048 * 2);
    expect(e.kvCache, 234881024); // 224 MiB
  });

  test(
    'compute buffer is close to the 282.5 MiB measured by llama.cpp at 2048 ctx',
    () {
      final e = estimateMemory(llama32_3bFacts, 2048);
      final mibCompute = e.compute / mib;
      expect(mibCompute, greaterThan(270));
      expect(mibCompute, lessThan(300));
    },
  );

  test(
    'total is weights + KV + compute + overhead + margin, and margin is 15% of the rest',
    () {
      final e = estimateMemory(llama32_3bFacts, 2048);
      final subtotal = e.weights + e.kvCache + e.compute + e.overhead;
      expect(e.margin, (subtotal * 0.15).ceil());
      expect(e.total, subtotal + e.margin);
    },
  );

  test(
    'Llama 3.2 3B at 2048 tokens fits the 8 GB planning budget with room to spare',
    () {
      final e = estimateMemory(llama32_3bFacts, 2048);
      expect(e.total, lessThan(MemoryPolicy.budgetBytes));
      expect(e.total, greaterThan(2 * gib));
    },
  );

  test('max context is capped at 8192 and never exceeds the budget', () {
    final ctx = maxContextFor(llama32_3bFacts);
    expect(ctx, 8192);
    expect(
      estimateMemory(llama32_3bFacts, ctx!).total,
      lessThanOrEqualTo(MemoryPolicy.budgetBytes),
    );
  });

  test('max context is a multiple of the step size', () {
    final ctx = maxContextFor(llama32_3bFacts, budgetBytes: 3 * gib)!;
    expect(ctx % MemoryPolicy.contextStepTokens, 0);
    expect(
      estimateMemory(llama32_3bFacts, ctx).total,
      lessThanOrEqualTo(3 * gib),
    );
    expect(
      estimateMemory(
        llama32_3bFacts,
        ctx + MemoryPolicy.contextStepTokens,
      ).total,
      greaterThan(3 * gib),
    );
  });

  test('returns null when even the minimum context does not fit', () {
    expect(maxContextFor(llama32_3bFacts, budgetBytes: 2 * gib), isNull);
  });

  test(
    'a model trained on a shorter context is limited by its training length',
    () {
      const short = ModelFacts(
        arch: 'llama',
        nLayer: 28,
        nHead: 24,
        nHeadKv: 8,
        nEmbd: 3072,
        headDim: 128,
        nCtxTrain: 4096,
        nVocab: 128256,
        sizeBytes: 2019377696,
      );
      expect(maxContextFor(short), 4096);
    },
  );
}
