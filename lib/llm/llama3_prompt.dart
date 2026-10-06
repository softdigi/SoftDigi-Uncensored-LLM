export 'chat_prompt.dart' show escapeControlTokens;

import 'chat_prompt.dart';

/// Formats a single-turn Llama 3 Instruct prompt. Kept for existing callers;
/// new code should use [buildChatPrompt] with a [PromptFormat].
///
/// The BOS token is added by the native tokenizer, so it is not written here.
String buildLlama3Prompt({required String userMessage, String? systemMessage}) {
  return buildChatPrompt(PromptFormat.llama3, [
    if (systemMessage != null) ChatMessage(ChatRole.system, systemMessage),
    ChatMessage(ChatRole.user, userMessage),
  ]);
}
