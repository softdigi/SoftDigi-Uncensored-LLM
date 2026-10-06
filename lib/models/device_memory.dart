import 'dart:io';

/// Memory the app can count on right now, in bytes:
/// MemFree + Inactive(file).
///
/// Inactive file pages are cache the kernel can reclaim first. Active file pages
/// (in use recently) and reclaimable slab are not counted, so this is conservative
/// compared with MemAvailable. Android's virtual or extended RAM is not included.
///
/// Returns 0 if /proc/meminfo cannot be read, so the gate refuses to load.
Future<int> readUsableRamBytes() async {
  try {
    final fields = <String, int>{};
    for (final line in await File('/proc/meminfo').readAsLines()) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon);
      if (key == 'MemFree' || key == 'Inactive(file)') {
        fields[key] = int.parse(
          line.substring(colon + 1).replaceAll(RegExp(r'[^0-9]'), ''),
        );
      }
    }
    final free = fields['MemFree'];
    final inactiveFile = fields['Inactive(file)'];
    if (free == null || inactiveFile == null) return 0;
    return (free + inactiveFile) * 1024;
  } catch (_) {
    // Not Linux, or no permission.
    return 0;
  }
}
