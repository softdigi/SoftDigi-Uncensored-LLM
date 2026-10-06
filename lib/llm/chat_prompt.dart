/// Chat templates for the supported model families.
///
/// Every message's text is passed through [escapeControlTokens], so user input
/// cannot contain a control token. The native tokenizer parses `<|...|>` as
/// special tokens, which would otherwise let input end a turn or inject a role.
library;

enum ChatRole { system, user, assistant }

class ChatMessage {
  const ChatMessage(this.role, this.text);

  final ChatRole role;
  final String text;
}

/// Prompt templates. Each profile names one of these.
enum PromptFormat {
  /// Llama 3 Instruct. The native tokenizer adds BOS.
  llama3,

  /// ChatML, used by Qwen2/Qwen2.5-family models.
  chatml,
}

/// Replaces every `<|` with `<` + U+200B + `|`. The tokenizer then reads the
/// text as plain characters; a reader sees the same text.
String escapeControlTokens(String text) {
  return text.replaceAll('<|', '<​|');
}

/// Builds the full prompt for [messages], ending with the assistant header so
/// the model writes the reply.
String buildChatPrompt(PromptFormat format, List<ChatMessage> messages) {
  final out = StringBuffer();
  switch (format) {
    case PromptFormat.llama3:
      for (final m in messages) {
        out.write(
          '<|start_header_id|>${_llama3Role(m.role)}<|end_header_id|>\n\n',
        );
        out.write(escapeControlTokens(m.text.trim()));
        out.write('<|eot_id|>');
      }
      out.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    case PromptFormat.chatml:
      for (final m in messages) {
        out.write('<|im_start|>${_chatmlRole(m.role)}\n');
        out.write(escapeControlTokens(m.text.trim()));
        out.write('<|im_end|>\n');
      }
      out.write('<|im_start|>assistant\n');
  }
  return out.toString();
}

String _llama3Role(ChatRole role) => switch (role) {
  ChatRole.system => 'system',
  ChatRole.user => 'user',
  ChatRole.assistant => 'assistant',
};

String _chatmlRole(ChatRole role) => switch (role) {
  ChatRole.system => 'system',
  ChatRole.user => 'user',
  ChatRole.assistant => 'assistant',
};
