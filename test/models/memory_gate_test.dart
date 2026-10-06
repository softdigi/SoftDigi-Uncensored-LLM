import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/llm/model_facts.dart';
import 'package:soft_local_pai/models/device_memory.dart';
import 'package:soft_local_pai/models/memory_estimator.dart';
import 'package:soft_local_pai/models/memory_gate.dart';

import 'fake_runtime.dart';

void main() {
  final estimate = estimateMemory(llama32_3bFacts, 2048);
  final required = MemoryGate.requiredBytes(estimate);

  test(
    'required memory is the non-weight footprint with margin, plus the reserve',
    () {
      final nonWeights =
          estimate.kvCache + estimate.compute + estimate.overhead;
      expect(
        required,
        (nonWeights * 1.15).ceil() + MemoryGate.liveReserveBytes,
      );
      expect(required, lessThan(estimate.total));
    },
  );

  test('weights do not change the requirement', () {
    const bigger = ModelFacts(
      arch: 'llama',
      nLayer: 28,
      nHead: 24,
      nHeadKv: 8,
      nEmbd: 3072,
      headDim: 128,
      nCtxTrain: 131072,
      nVocab: 128256,
      sizeBytes: 9 * gib,
    );
    expect(MemoryGate.requiredBytes(estimateMemory(bigger, 2048)), required);
  });

  test('clearly short of the requirement is insufficient', () {
    final r = MemoryGate.check(usableBytes: required - 1, estimate: estimate);
    expect(r.verdict, GateVerdict.insufficient);
    expect(r.allowed, isFalse);
    expect(r.userMessage, contains('Close other apps'));
  });

  test('zero usable memory (unreadable meminfo) is refused', () {
    final r = MemoryGate.check(usableBytes: 0, estimate: estimate);
    expect(r.allowed, isFalse);
  });

  test('covered but inside the safety margin is borderline and refused', () {
    final r = MemoryGate.check(usableBytes: required, estimate: estimate);
    expect(r.verdict, GateVerdict.borderline);
    expect(r.allowed, isFalse);
    expect(r.userMessage, contains('too tight'));
  });

  test('covered with the full safety margin is allowed', () {
    final needed = (required * (1 + MemoryPolicy.marginFraction)).ceil();
    final r = MemoryGate.check(usableBytes: needed, estimate: estimate);
    expect(r.verdict, GateVerdict.allow);
    expect(r.allowed, isTrue);
  });

  test(
    'the device state that the old gate refused (2831 MB raw available) is allowed',
    () {
      // Measured on the phone: MemFree 182 MB + Inactive(file) 1924 MB.
      const usable = (182 + 1924) * mib;
      final r = MemoryGate.check(usableBytes: usable, estimate: estimate);
      expect(r.allowed, isTrue, reason: r.userMessage);
    },
  );

  test('reading usable memory never throws', () async {
    expect(await readUsableRamBytes(), isA<int>());
  });
}
