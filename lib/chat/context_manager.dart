import '../llm/chat_prompt.dart';

class ContextTooLargeException implements Exception {
  const ContextTooLargeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The messages to send for one turn, and how many tokens they use.
class FittedPrompt {
  const FittedPrompt({
    required this.prompt,
    required this.promptTokens,
    required this.droppedMessages,
  });

  /// The full prompt text, ready for generate().
  final String prompt;

  /// Tokens of the prompt, including BOS.
  final int promptTokens;

  /// Oldest history messages left out of this prompt. The full transcript is kept elsewhere.
  final int droppedMessages;
}

/// Fits a conversation into the context window.
///
/// Keeps the system prompt, the newest user message and as much recent history as fits,
/// leaving room for the reply. Drops the oldest turns first. Token counts come from the
/// loaded model's tokenizer, so the count is exact for the prompt the engine evaluates.
class ContextManager {
  ContextManager({
    required this.format,
    required this.contextTokens,
    required this.maxNewTokens,
    required this.countTokens,
    this.systemPrompt,
    this.replySafetyTokens = 32,
  });

  final PromptFormat format;
  final int contextTokens;

  /// Room reserved for the reply.
  final int maxNewTokens;

  /// Counts tokens of plain text under the loaded model's tokenizer.
  final Future<int> Function(String text) countTokens;

  final String? systemPrompt;

  /// Extra tokens kept free beyond the reply, as slack for tokenizer differences.
  final int replySafetyTokens;

  /// Tokens the reply may use with the current settings.
  int get replyBudget => maxNewTokens;

  /// Fits [history] plus [userMessage] into the window.
  /// Throws ContextTooLargeException if the newest message alone does not fit.
  Future<FittedPrompt> fit(
    List<ChatMessage> history,
    ChatMessage userMessage,
  ) async {
    final limit = contextTokens - maxNewTokens - replySafetyTokens;
    var start = 0;
    while (true) {
      final messages = [
        if (systemPrompt != null) ChatMessage(ChatRole.system, systemPrompt!),
        ...history.sublist(start),
        userMessage,
      ];
      final prompt = buildChatPrompt(format, messages);
      // The engine adds BOS in front of the prompt, so count one extra token.
      final tokens = await countTokens(prompt) + 1;
      if (tokens <= limit) {
        return FittedPrompt(
          prompt: prompt,
          promptTokens: tokens,
          droppedMessages: start,
        );
      }
      if (start >= history.length) {
        throw ContextTooLargeException(
          'the new message does not fit: $tokens prompt tokens, room for $limit '
          '(context $contextTokens minus reply $maxNewTokens and slack $replySafetyTokens)',
        );
      }
      // Drop the oldest turn. Turns come as user/assistant pairs, so drop two when possible.
      start += (start + 1 < history.length) ? 2 : 1;
    }
  }
}
