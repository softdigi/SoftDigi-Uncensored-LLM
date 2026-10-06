import 'dart:io';

/// RAM the kernel reports as available (MemAvailable), in bytes. Returns 0 if unreadable.
/// Android's virtual or extended RAM is not included.
Future<int> readAvailableRamBytes() async {
  try {
    for (final line in await File('/proc/meminfo').readAsLines()) {
      if (line.startsWith('MemAvailable:')) {
        final kb = int.parse(line.replaceAll(RegExp(r'[^0-9]'), ''));
        return kb * 1024;
      }
    }
  } catch (_) {
    // Not Linux or no permission: report 0 so the caller refuses to load.
  }
  return 0;
}
