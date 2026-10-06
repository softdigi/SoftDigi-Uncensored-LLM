import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/models/thermal_policy.dart';

void main() {
  test('none and light run normally with the suggested threads and no cap', () {
    for (final level in [ThermalLevel.none, ThermalLevel.light]) {
      final d = decideThermal(
        level,
        suggestedThreads: 4,
        requestedMaxTokens: 512,
      );
      expect(d.allowGeneration, isTrue);
      expect(d.threads, 4);
      expect(d.maxNewTokensCap, isNull);
      expect(d.unloadModel, isFalse);
    }
  });

  test(
    'moderate reduces threads by 2 (min 1) and caps replies at 256 tokens',
    () {
      final d = decideThermal(
        ThermalLevel.moderate,
        suggestedThreads: 4,
        requestedMaxTokens: 512,
      );
      expect(d.allowGeneration, isTrue);
      expect(d.threads, 2);
      expect(d.maxNewTokensCap, 256);

      final low = decideThermal(
        ThermalLevel.moderate,
        suggestedThreads: 2,
        requestedMaxTokens: 100,
      );
      expect(low.threads, 1);
      expect(low.maxNewTokensCap, 100);
    },
  );

  test('severe pauses generation without unloading', () {
    final d = decideThermal(
      ThermalLevel.severe,
      suggestedThreads: 4,
      requestedMaxTokens: 512,
    );
    expect(d.allowGeneration, isFalse);
    expect(d.unloadModel, isFalse);
  });

  test('critical and above pause generation and unload the model', () {
    for (final level in [
      ThermalLevel.critical,
      ThermalLevel.emergency,
      ThermalLevel.shutdown,
    ]) {
      final d = decideThermal(
        level,
        suggestedThreads: 4,
        requestedMaxTokens: 512,
      );
      expect(d.allowGeneration, isFalse);
      expect(d.unloadModel, isTrue);
    }
  });

  test('unknown codes map to none', () {
    expect(thermalLevelFromCode(-1), ThermalLevel.none);
    expect(thermalLevelFromCode(3), ThermalLevel.severe);
    expect(thermalLevelFromCode(99), ThermalLevel.none);
  });
}
