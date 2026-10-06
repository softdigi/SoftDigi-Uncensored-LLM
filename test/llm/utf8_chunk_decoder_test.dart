import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/llm/llm_engine.dart';

void main() {
  test('joins a multi-byte character split across chunks', () {
    final bytes = utf8.encode('café ✓');
    final decoder = Utf8ChunkDecoder();
    final out = StringBuffer();
    // Feed one byte at a time so every multi-byte character is split.
    for (final b in bytes) {
      out.write(decoder.add(Uint8List.fromList([b])));
    }
    out.write(decoder.close());
    expect(out.toString(), 'café ✓');
  });

  test('holds back an incomplete tail until it completes', () {
    final euro = utf8.encode('€'); // 3 bytes
    final decoder = Utf8ChunkDecoder();
    expect(decoder.add(Uint8List.fromList([0x61, euro[0]])), 'a');
    expect(decoder.add(Uint8List.fromList([euro[1]])), '');
    expect(decoder.add(Uint8List.fromList([euro[2]])), '€');
    expect(decoder.close(), '');
  });

  test('close replaces a dangling partial sequence with U+FFFD', () {
    final decoder = Utf8ChunkDecoder();
    expect(decoder.add(Uint8List.fromList([0xE2, 0x82])), '');
    expect(decoder.close(), '�');
  });
}
