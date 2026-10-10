import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soft_local_pai/search/search_result.dart';
import 'package:soft_local_pai/search/web_search_service.dart';

/// Returns a canned JSON response and records the request it was called
/// with, so tests can inspect the exact request without a real socket.
class _RecordingClient extends http.BaseClient {
  http.BaseRequest? lastRequest;
  String body = '{"results": []}';
  int statusCode = 200;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    final bytes = utf8.encode(body);
    return http.StreamedResponse(Stream.value(bytes), statusCode);
  }
}

void main() {
  group('SearxngWebSearchService configuration', () {
    test('is not configured when no endpoint is given', () {
      final service = SearxngWebSearchService(endpoint: null);
      expect(service.isConfigured, isFalse);
    });

    test('is not configured for an empty endpoint', () {
      final service = SearxngWebSearchService(endpoint: '');
      expect(service.isConfigured, isFalse);
    });

    test('is not configured for a plain-HTTP endpoint', () {
      // No cleartext traffic, ever: an http:// URL is rejected outright.
      final service = SearxngWebSearchService(
        endpoint: 'http://search.example/search',
      );
      expect(service.isConfigured, isFalse);
    });

    test('is configured for a well-formed HTTPS endpoint', () {
      final service = SearxngWebSearchService(
        endpoint: 'https://search.softdigi.example/search',
      );
      expect(service.isConfigured, isTrue);
    });

    test('search() throws when not configured, without a network attempt', () async {
      final client = _RecordingClient();
      final service = SearxngWebSearchService(endpoint: null, client: client);
      await expectLater(
        () => service.search('today weather'),
        throwsA(isA<WebSearchException>()),
      );
      expect(client.lastRequest, isNull);
    });
  });

  group('SearxngWebSearchService request shape', () {
    test('sends no Authorization/API-key header to the self-hosted endpoint', () async {
      final client = _RecordingClient();
      final service = SearxngWebSearchService(
        endpoint: 'https://search.softdigi.example/search',
        client: client,
      );
      await service.search('today weather');
      final headers = client.lastRequest!.headers;
      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers.containsKey('X-Api-Key'), isFalse);
      expect(headers.containsKey('authorization'), isFalse);
    });

    test('requests format=json and the query against the configured host', () async {
      final client = _RecordingClient();
      final service = SearxngWebSearchService(
        endpoint: 'https://search.softdigi.example/search',
        client: client,
      );
      await service.search('today gold price');
      final uri = client.lastRequest!.url;
      expect(uri.scheme, 'https');
      expect(uri.host, 'search.softdigi.example');
      expect(uri.queryParameters['format'], 'json');
      expect(uri.queryParameters['q'], 'today gold price');
    });

    test('parses title/url/content from the SearXNG JSON shape', () async {
      final client = _RecordingClient()
        ..body = jsonEncode({
          'results': [
            {
              'title': 'Today\'s gold price',
              'url': 'https://example.com/gold',
              'content': 'Gold is at a price that changes daily.',
            },
          ],
        });
      final service = SearxngWebSearchService(
        endpoint: 'https://search.softdigi.example/search',
        client: client,
      );
      final results = await service.search('gold price');
      expect(results, hasLength(1));
      expect(results.single, isA<SearchResult>());
      expect(results.single.title, "Today's gold price");
      expect(results.single.url, 'https://example.com/gold');
      expect(results.single.snippet, 'Gold is at a price that changes daily.');
    });

    test(
      'malformed result fields (wrong type, missing, null) are treated as '
      'empty, never thrown — a single bad engine result must not crash a search',
      () async {
        final client = _RecordingClient()
          ..body = jsonEncode({
            'results': [
              // A well-formed result.
              {
                'title': 'Good result',
                'url': 'https://example.com/good',
                'content': 'Fine.',
                'engine': 'duckduckgo',
              },
              // Wrong types where strings are expected.
              {'title': 12345, 'url': null, 'content': {'nested': true}},
              // Not a map at all.
              'not even an object',
              42,
              null,
            ],
          });
        final service = SearxngWebSearchService(
          endpoint: 'https://search.softdigi.example/search',
          client: client,
        );
        final results = await service.search('anything');
        expect(results, hasLength(2));
        expect(results[0].title, 'Good result');
        expect(results[0].engine, 'duckduckgo');
        expect(results[1].title, '');
        expect(results[1].url, '');
        expect(results[1].snippet, '');
      },
    );

    test('a non-200 response throws WebSearchException', () async {
      final client = _RecordingClient()..statusCode = 503;
      final service = SearxngWebSearchService(
        endpoint: 'https://search.softdigi.example/search',
        client: client,
      );
      await expectLater(
        () => service.search('today weather'),
        throwsA(isA<WebSearchException>()),
      );
    });
  });
}
