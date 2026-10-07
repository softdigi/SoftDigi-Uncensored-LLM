import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/app/widgets/message_content.dart';

void main() {
  test('plain text is one prose part', () {
    final parts = parseMessage('Hello there.');
    expect(parts.length, 1);
    expect(parts.single.isCode, isFalse);
    expect(parts.single.text, 'Hello there.');
  });

  test('a fenced block becomes a code part with its language', () {
    final parts = parseMessage(
      'Here:\n```python\ndef f(n):\n    return n\n```\nDone.',
    );
    final code = parts.where((p) => p.isCode).toList();
    expect(code.length, 1);
    expect(code.single.language, 'python');
    expect(code.single.text, 'def f(n):\n    return n');
    expect(parts.last.text, 'Done.');
  });

  test('an open fence while streaming is shown as code so far', () {
    final parts = parseMessage('```dart\nvoid main() {');
    final code = parts.where((p) => p.isCode).toList();
    expect(code.single.text, 'void main() {');
  });

  test('text with no fence is never treated as code', () {
    final parts = parseMessage('Use `inline` code.');
    expect(parts.every((p) => !p.isCode), isTrue);
  });
}
