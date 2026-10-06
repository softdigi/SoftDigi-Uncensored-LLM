/// Android thermal status levels (PowerManager.THERMAL_STATUS_*).
enum ThermalLevel {
  none,
  light,
  moderate,
  severe,
  critical,
  emergency,
  shutdown,
}

ThermalLevel thermalLevelFromCode(int code) {
  if (code < 0 || code >= ThermalLevel.values.length) return ThermalLevel.none;
  return ThermalLevel.values[code];
}

/// What the app may do at a given thermal level.
class ThermalDecision {
  const ThermalDecision({
    required this.allowGeneration,
    required this.threads,
    required this.maxNewTokensCap,
    required this.unloadModel,
    required this.message,
  });

  final bool allowGeneration;

  /// Thread count for generation.
  final int threads;

  /// Upper bound on new tokens per reply. Null means no cap.
  final int? maxNewTokensCap;

  /// True when the model should be freed to cut heat and memory use.
  final bool unloadModel;

  final String message;
}

/// Thermal rules:
/// - none/light: normal operation.
/// - moderate: fewer threads (suggested - 2, at least 1) and at most 256 new tokens.
/// - severe: no new generation until the device cools.
/// - critical and above: no generation, and the model is unloaded.
ThermalDecision decideThermal(
  ThermalLevel level, {
  required int suggestedThreads,
  required int requestedMaxTokens,
}) {
  switch (level) {
    case ThermalLevel.none:
    case ThermalLevel.light:
      return ThermalDecision(
        allowGeneration: true,
        threads: suggestedThreads,
        maxNewTokensCap: null,
        unloadModel: false,
        message: 'ok',
      );
    case ThermalLevel.moderate:
      final reduced = suggestedThreads - 2;
      return ThermalDecision(
        allowGeneration: true,
        threads: reduced < 1 ? 1 : reduced,
        maxNewTokensCap: requestedMaxTokens < 256 ? requestedMaxTokens : 256,
        unloadModel: false,
        message: 'device is warm: fewer threads and shorter replies',
      );
    case ThermalLevel.severe:
      return const ThermalDecision(
        allowGeneration: false,
        threads: 1,
        maxNewTokensCap: null,
        unloadModel: false,
        message: 'device is hot: generation paused until it cools',
      );
    case ThermalLevel.critical:
    case ThermalLevel.emergency:
    case ThermalLevel.shutdown:
      return const ThermalDecision(
        allowGeneration: false,
        threads: 1,
        maxNewTokensCap: null,
        unloadModel: true,
        message: 'device is overheating: model unloaded',
      );
  }
}
