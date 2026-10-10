import 'dart:convert';

import 'package:http/http.dart' as http;

import 'search_result.dart';

class WebSearchException implements Exception {
  const WebSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Looks up [query] against a self-hosted search backend and returns raw
/// (not yet cleaned/truncated) results. The only implementation in this app
/// is [SearxngWebSearchService] — there is no cloud search or cloud LLM
/// client anywhere in the codebase.
abstract interface class WebSearchService {
  /// True when an endpoint has been configured for this build. Web Search
  /// stays unavailable until this is true, regardless of the user's chosen
  /// [SearchMode] — there is no default endpoint baked into source.
  bool get isConfigured;

  Future<List<SearchResult>> search(String query);
}

/// Talks to a self-hosted SearXNG instance's JSON search API
/// (`GET {endpoint}?q=...&format=json`). SoftDigi Technology controls the
/// instance this points to; no API key is used or needed because the
/// endpoint is not a third-party paid service.
///
/// The endpoint is never hardcoded: it comes from a `--dart-define` set at
/// build time (see README), so it can be left unset entirely in source
/// control and in builds where Web Search should stay off.
class SearxngWebSearchService implements WebSearchService {
  SearxngWebSearchService({String? endpoint, http.Client? client})
    : _endpoint = _validated(endpoint),
      _client = client ?? http.Client();

  final Uri? _endpoint;
  final http.Client _client;

  static Uri? _validated(String? endpoint) {
    if (endpoint == null || endpoint.trim().isEmpty) return null;
    final uri = Uri.tryParse(endpoint.trim());
    // Self-hosted endpoint only, and HTTPS only: this app never sends a
    // search query over plaintext HTTP.
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  @override
  bool get isConfigured => _endpoint != null;

  @override
  Future<List<SearchResult>> search(String query) async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const WebSearchException('Web Search is not configured.');
    }
    final url = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'q': query,
        'format': 'json',
      },
    );
    final http.Response response;
    try {
      response = await _client
          .get(url, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      throw const WebSearchException(
        'Could not reach the search server. Check your connection.',
      );
    }
    if (response.statusCode != 200) {
      throw WebSearchException(
        'The search server returned an error (${response.statusCode}).',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const WebSearchException('The search server reply was unreadable.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const WebSearchException('The search server reply was unreadable.');
    }
    final results = decoded['results'];
    if (results is! List) return const [];
    // Each field is read defensively: a single result with an unexpected
    // shape (a different SearXNG version, an engine plugin returning a
    // number or nested object where a string is expected, etc.) must never
    // throw here. Throwing would escape the caller's WebSearchException
    // handling and leave the chat stuck mid-generation — so any field that
    // isn't a plain string is treated as missing, not as a crash.
    return [
      for (final r in results)
        if (r is Map<Object?, Object?>)
          SearchResult(
            title: _asString(r['title']),
            url: _asString(r['url']),
            snippet: _asString(r['content']),
            engine: _asStringOrNull(r['engine']),
            category: _asStringOrNull(r['category']),
          ),
    ];
  }

  static String _asString(Object? value) =>
      value is String ? value.trim() : '';

  static String? _asStringOrNull(Object? value) {
    final s = _asString(value);
    return s.isEmpty ? null : s;
  }
}
