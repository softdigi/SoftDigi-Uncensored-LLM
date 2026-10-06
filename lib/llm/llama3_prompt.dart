/// Llama 3 (and most ChatML-style) control tokens all have the form `<|...|>`.
/// The native tokenizer parses these as special tokens, so untrusted text
/// containing one could end a turn or inject a role header.
///
/// Every `<|` in user or system text is written as `<` + U+200B (zero-width
/// space) + `|`. The tokenizer then sees plain text, and the reader sees the
/// same characters, except for an invisible separator.
String escapeControlTokens(String text) {
  return text.replaceAll('<|', '<​|');
}

/// Formats a Llama 3 Instruct chat turn.
///
/// The BOS token (<|begin_of_text|>) is not written here: the native tokenizer
/// adds it. Message text is escaped with [escapeControlTokens]. The output ends
/// with the assistant header so the model writes the reply.
String buildLlama3Prompt({required String userMessage, String? systemMessage}) {
  final system = systemMessage == null
      ? ''
      : '<|start_header_id|>system<|end_header_id|>\n\n'
            '${escapeControlTokens(systemMessage.trim())}<|eot_id|>';
  return '$system'
      '<|start_header_id|>user<|end_header_id|>\n\n'
      '${escapeControlTokens(userMessage.trim())}<|eot_id|>'
      '<|start_header_id|>assistant<|end_header_id|>\n\n';
}
