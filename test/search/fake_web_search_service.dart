import 'package:soft_local_pai/search/search_result.dart';
import 'package:soft_local_pai/search/web_search_service.dart';

/// Records every call so tests can assert whether (and how) the network
/// would have been used, without ever touching a real socket.
class FakeWebSearchService implements WebSearchService {
  FakeWebSearchService({this.configured = true});

  bool configured;

  @override
  bool get isConfigured => configured;

  final List<String> queries = [];
  int get callCount => queries.length;

  List<SearchResult> results = const [
    SearchResult(
      title: "Today's gold price",
      url: 'https://example.com/gold-price',
      snippet: 'Gold is trading at a price that changes every day.',
    ),
  ];

  /// When set, [search] throws this instead of returning [results].
  WebSearchException? failWith;

  /// When true, [search] throws a plain [StateError] instead of a
  /// [WebSearchException] — simulates a bug or unanticipated failure in a
  /// WebSearchService implementation, to prove the caller still recovers.
  bool throwUnexpected = false;

  @override
  Future<List<SearchResult>> search(String query) async {
    queries.add(query);
    if (throwUnexpected) throw StateError('unexpected failure');
    if (failWith != null) throw failWith!;
    return results;
  }
}
