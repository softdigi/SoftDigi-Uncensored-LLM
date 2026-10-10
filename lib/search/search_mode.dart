/// How much network access the user has allowed for web search.
enum SearchMode {
  /// Never access the network, regardless of what a message seems to need.
  localOnly,

  /// Default. A message that looks like it needs current information triggers
  /// an explicit Allow/Cancel prompt before any network request is made.
  smart,

  /// The user has granted standing permission: a message that looks like it
  /// needs current information is searched without asking each time. Still
  /// only the self-hosted SearXNG endpoint is ever contacted — no cloud LLM
  /// is used in this mode or any other.
  webSearchAllowed,
}

String searchModeLabel(SearchMode mode) => switch (mode) {
  SearchMode.localOnly => 'Local Only',
  SearchMode.smart => 'Smart',
  SearchMode.webSearchAllowed => 'Web Search Allowed',
};

SearchMode searchModeFromName(String? name) => SearchMode.values.firstWhere(
  (m) => m.name == name,
  orElse: () => SearchMode.smart,
);
