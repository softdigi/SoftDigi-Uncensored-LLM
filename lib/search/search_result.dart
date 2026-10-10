/// One web search result, already cleaned and truncated. Shown to the user as
/// a source and handed to the local model as reference data only.
class SearchResult {
  const SearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.engine,
    this.category,
  });

  factory SearchResult.fromJson(Map<String, Object?> json) => SearchResult(
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    snippet: json['snippet'] as String? ?? '',
    engine: json['engine'] as String?,
    category: json['category'] as String?,
  );

  final String title;
  final String url;
  final String snippet;

  /// Which SearXNG engine returned this result (e.g. "google", "duckduckgo"),
  /// when SearXNG reports one. Informational only — never required.
  final String? engine;

  /// SearXNG's result category (e.g. "general", "news"), when reported.
  /// Informational only — never required.
  final String? category;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'snippet': snippet,
    if (engine != null) 'engine': engine,
    if (category != null) 'category': category,
  };
}
