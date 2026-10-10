/// Decides, without any network access or model call, whether a message looks
/// like it needs current information from the web.
///
/// This is a deterministic keyword heuristic, not a model-driven judgement: it
/// costs no inference time or battery, and it is exact and repeatable for
/// tests. It only ever gates whether a search is *offered* — the user (in
/// Smart mode) or the Web Search Allowed setting always has the final say
/// before any network request happens.
class SearchDecision {
  const SearchDecision._();

  /// Phrases that strongly suggest the answer depends on information that
  /// changes over time (today's date, this week's news, a live price, etc.)
  /// and so cannot be answered reliably from a static local model alone.
  static const List<String> _triggerPhrases = [
    'today',
    "today's",
    'tonight',
    'this week',
    'this month',
    'this year',
    'right now',
    'currently',
    'current',
    'latest',
    'recent',
    'recently',
    'up to date',
    'up-to-date',
    'as of',
    'live score',
    'live update',
    'breaking news',
    'news',
    'headline',
    'weather',
    'forecast',
    'stock price',
    'share price',
    'exchange rate',
    'gold price',
    'crypto price',
    'who won',
    'election result',
    'score',
    'search for',
    'look up',
    'google ',
  ];

  /// True when [text] contains a trigger phrase, matched as whole words so
  /// "current" does not match inside an unrelated longer word.
  static bool needsWebSearch(String text) {
    final lower = text.toLowerCase();
    for (final phrase in _triggerPhrases) {
      final pattern = RegExp(
        r'(?<![a-z0-9])' + RegExp.escape(phrase.trim()) + r'(?![a-z0-9])',
      );
      if (pattern.hasMatch(lower)) return true;
    }
    return false;
  }
}
