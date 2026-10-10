import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hosts of paid/cloud LLM APIs. None of these may ever appear in lib/: this
/// app's only network call is to a self-hosted SearXNG endpoint, and final
/// reasoning always happens in the on-device GGUF model.
const List<String> _bannedCloudLlmHosts = [
  'api.openai.com',
  'api.anthropic.com',
  'generativelanguage.googleapis.com',
  'api.cohere.ai',
  'api.mistral.ai',
  'openrouter.ai',
  'api.together.xyz',
  'api.groq.com',
];

/// Hosts of paid/third-party search APIs. The only search backend this app
/// may ever call is a self-hosted SearXNG instance, configured at build
/// time via --dart-define, never one of these.
const List<String> _bannedPaidSearchHosts = [
  'api.bing.com',
  'serpapi.com',
  'tavily.com',
  'exa.ai',
  'api.perplexity.ai',
  'customsearch.googleapis.com',
  'cse.google.com',
];

/// Field/variable names that would suggest a secret is embedded in source.
/// A self-hosted SearXNG JSON endpoint needs no API key, so none of this
/// app's code should ever define one.
final RegExp _apiKeyLikeAssignment = RegExp(
  r'''(api[_-]?key|apikey|secret[_-]?key|access[_-]?token)\s*[:=]\s*['"][^'"]+['"]''',
  caseSensitive: false,
);

Iterable<File> _dartFiles(Directory dir) =>
    dir.listSync(recursive: true).whereType<File>().where(
      (f) => f.path.endsWith('.dart'),
    );

void main() {
  final lib = Directory('lib');

  test('no cloud LLM API host appears anywhere in lib/', () {
    for (final file in _dartFiles(lib)) {
      final text = file.readAsStringSync().toLowerCase();
      for (final host in _bannedCloudLlmHosts) {
        expect(
          text.contains(host),
          isFalse,
          reason: '${file.path} mentions a cloud LLM API host: $host',
        );
      }
    }
  });

  test('no paid/third-party search API host appears anywhere in lib/', () {
    for (final file in _dartFiles(lib)) {
      final text = file.readAsStringSync().toLowerCase();
      for (final host in _bannedPaidSearchHosts) {
        expect(
          text.contains(host),
          isFalse,
          reason: '${file.path} mentions a paid search API host: $host',
        );
      }
    }
  });

  test('no API key or secret literal is embedded in lib/', () {
    for (final file in _dartFiles(lib)) {
      final text = file.readAsStringSync();
      final match = _apiKeyLikeAssignment.firstMatch(text);
      expect(
        match,
        isNull,
        reason: match == null
            ? null
            : '${file.path} appears to embed a secret: "${match.group(0)}"',
      );
    }
  });

  test(
    'the search client never sends an Authorization or API-key header by default',
    () {
      final client = File('lib/search/web_search_service.dart').readAsStringSync();
      expect(client, isNot(contains('Authorization')));
      expect(client.toLowerCase(), isNot(contains('x-api-key')));
    },
  );
}
