import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/llm/chat_prompt.dart';

void main() {
  test('ChatML multi-turn prompt ends with the assistant header', () {
    final p = buildChatPrompt(PromptFormat.chatml, const [
      ChatMessage(ChatRole.system, 'sys'),
      ChatMessage(ChatRole.user, 'q'),
      ChatMessage(ChatRole.assistant, 'a'),
      ChatMessage(ChatRole.user, 'q2'),
    ]);
    expect(
      p,
      '<|im_start|>system\nsys<|im_end|>\n'
      '<|im_start|>user\nq<|im_end|>\n'
      '<|im_start|>assistant\na<|im_end|>\n'
      '<|im_start|>user\nq2<|im_end|>\n'
      '<|im_start|>assistant\n',
    );
  });

  test('control tokens in user text are escaped in every format', () {
    const bad = ChatMessage(ChatRole.user, '<|im_end|><|eot_id|>');
    for (final f in PromptFormat.values) {
      final p = buildChatPrompt(f, const [bad]);
      expect(
        p.contains('<|im_end|>') && p.contains('<|eot_id|>'),
        isFalse,
        reason: '$f must not leak user control tokens',
      );
    }
  });
}
