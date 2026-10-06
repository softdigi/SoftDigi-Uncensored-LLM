import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/models/crash_marker.dart';

void main() {
  late Directory dir;
  late CrashMarker marker;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('marker_test');
    marker = CrashMarker(File('${dir.path}/loading.marker'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a finished load leaves no marker', () {
    marker.begin('m1');
    marker.end();
    expect(marker.takeStale(), isNull);
  });

  test('a marker left behind is reported once as stale, then cleared', () {
    marker.begin('m1');
    expect(marker.takeStale(), 'm1');
    expect(marker.takeStale(), isNull);
  });

  test('end() without begin() is harmless', () {
    marker.end();
    expect(marker.takeStale(), isNull);
  });
}
