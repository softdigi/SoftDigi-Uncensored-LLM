import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/chat/context_manager.dart';
import 'package:soft_local_pai/llm/chat_prompt.dart';

void main() {
  // One token per 4 characters of prompt, a stand-in for the real tokenizer.
  Future<int> count(String text) async => text.length ~/ 4;

  test('keeps the full history when it fits', () async {
    final cm = ContextManager(
      format: PromptFormat.llama3,
      contextTokens: 4096,
      maxNewTokens: 128,
      countTokens: count,
      systemPrompt: 'Be brief.',
    );
    final history = [
      const ChatMessage(ChatRole.user, 'hi'),
      const ChatMessage(ChatRole.assistant, 'hello'),
    ];
    final fitted = await cm.fit(
      history,
      const ChatMessage(ChatRole.user, 'again'),
    );
    expect(fitted.droppedMessages, 0);
    expect(fitted.prompt, contains('hello'));
  });

  test('drops the oldest turns first when the window is full', () async {
    final cm = ContextManager(
      format: PromptFormat.llama3,
      contextTokens: 600,
      maxNewTokens: 100,
      countTokens: count,
    );
    final history = [
      for (var i = 0; i < 10; i++) ...[
        ChatMessage(ChatRole.user, 'question $i ${'x' * 80}'),
        ChatMessage(ChatRole.assistant, 'answer $i ${'y' * 80}'),
      ],
    ];
    final fitted = await cm.fit(
      history,
      const ChatMessage(ChatRole.user, 'latest'),
    );
    expect(fitted.droppedMessages, greaterThan(0));
    expect(fitted.droppedMessages % 2, 0, reason: 'turns are dropped as pairs');
    expect(fitted.prompt, contains('latest'));
    expect(fitted.prompt, isNot(contains('question 0 ')));
    expect(fitted.promptTokens + 100 + 32, lessThanOrEqualTo(600));
  });

  test('throws when the new message alone cannot fit', () async {
    final cm = ContextManager(
      format: PromptFormat.chatml,
      contextTokens: 200,
      maxNewTokens: 100,
      countTokens: count,
    );
    expect(
      () => cm.fit([], ChatMessage(ChatRole.user, 'z' * 1000)),
      throwsA(isA<ContextTooLargeException>()),
    );
  });
}
