import 'memory_estimator.dart';

/// Outcome of the live RAM check made just before a load.
enum GateVerdict {
  /// Enough usable memory with the safety margin included.
  allow,

  /// Usable memory is below what the load needs.
  insufficient,

  /// Usable memory covers the need, but only within the safety margin.
  /// Refused because the device may swap or the app may be killed.
  borderline,
}

class GateResult {
  const GateResult({
    required this.verdict,
    required this.usableBytes,
    required this.requiredBytes,
  });

  final GateVerdict verdict;
  final int usableBytes;
  final int requiredBytes;

  bool get allowed => verdict == GateVerdict.allow;

  /// A message the user can act on.
  String get userMessage {
    final have = usableBytes ~/ mib;
    final need = requiredBytes ~/ mib;
    switch (verdict) {
      case GateVerdict.allow:
        return 'enough memory: $have MB usable, $need MB needed';
      case GateVerdict.insufficient:
        return 'not enough free memory for this model right now: $need MB needed, '
            '$have MB usable. Close other apps and try again.';
      case GateVerdict.borderline:
        return 'memory is too tight to load safely: $need MB needed, $have MB usable '
            '(within the safety margin). Close other apps and try again.';
    }
  }
}

/// The live memory gate.
///
/// The model's weights are file-backed (memory-mapped). The kernel can reclaim
/// those pages, and the 60% budget already bounds them, so they are not checked
/// against live memory. Only the non-weight part of the footprint must fit in usable memory.
class MemoryGate {
  const MemoryGate._();

  /// Free memory kept in reserve on top of the load's own need, for the rest of the system.
  static const int liveReserveBytes = 512 * mib;

  /// Memory a load needs right now: KV cache, compute buffers and runtime overhead,
  /// with the safety margin applied to those parts only, plus the reserve.
  /// The weights are left out (see the class comment).
  static int requiredBytes(MemoryEstimate estimate) {
    final nonWeights = estimate.kvCache + estimate.compute + estimate.overhead;
    return (nonWeights * (1 + MemoryPolicy.marginFraction)).ceil() +
        liveReserveBytes;
  }

  /// Decides whether a load may start.
  /// [usableBytes] is MemFree plus Inactive(file), see readUsableRamBytes().
  static GateResult check({
    required int usableBytes,
    required MemoryEstimate estimate,
  }) {
    final required = requiredBytes(estimate);
    final GateVerdict verdict;
    if (usableBytes < required) {
      verdict = GateVerdict.insufficient;
    } else if (usableBytes <
        (required * (1 + MemoryPolicy.marginFraction)).ceil()) {
      verdict = GateVerdict.borderline;
    } else {
      verdict = GateVerdict.allow;
    }
    return GateResult(
      verdict: verdict,
      usableBytes: usableBytes,
      requiredBytes: required,
    );
  }
}
