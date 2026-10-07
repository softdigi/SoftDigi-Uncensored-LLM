import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Renders a reply: plain text, with fenced ```code``` blocks shown in a code panel.
/// Other Markdown syntax is shown as written.
class MessageContent extends StatelessWidget {
  const MessageContent({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final parts = parseMessage(text);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final part in parts)
          if (part.isCode)
            _CodeBlock(code: part.text, language: part.language)
          else if (part.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: SelectableText(
                part.text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: color,
                  height: 1.4,
                ),
              ),
            ),
      ],
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language});

  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.isEmpty ? 'code' : language,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy code',
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')),
                    );
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One piece of a reply: prose or a fenced code block.
class MessagePart {
  const MessagePart({
    required this.text,
    this.isCode = false,
    this.language = '',
  });

  final String text;
  final bool isCode;
  final String language;
}

/// Splits [text] on ``` fences. A fence still open at the end (a reply that is still
/// streaming) is treated as code so far, so the panel appears while it streams.
List<MessagePart> parseMessage(String text) {
  final parts = <MessagePart>[];
  final fence = RegExp(r'^```([^\n]*)$', multiLine: true);
  var cursor = 0;
  var inCode = false;
  var language = '';
  var start = 0;

  for (final match in fence.allMatches(text)) {
    final before = text.substring(cursor, match.start);
    if (!inCode) {
      parts.add(MessagePart(text: before.trimRight()));
      language = match.group(1)!.trim();
      start = match.end + 1 > text.length ? text.length : match.end + 1;
      inCode = true;
    } else {
      parts.add(
        MessagePart(
          text: text
              .substring(start, match.start)
              .replaceFirst(RegExp(r'\n$'), ''),
          isCode: true,
          language: language,
        ),
      );
      inCode = false;
    }
    cursor = match.end;
  }

  if (inCode) {
    final code = start <= text.length ? text.substring(start) : '';
    parts.add(
      MessagePart(
        text: code.replaceFirst(RegExp(r'\n$'), ''),
        isCode: true,
        language: language,
      ),
    );
  } else {
    parts.add(MessagePart(text: text.substring(cursor).trim()));
  }
  return parts.where((p) => p.text.isNotEmpty || p.isCode).toList();
}
