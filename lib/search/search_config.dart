/// The self-hosted SearXNG JSON search endpoint, e.g.
/// `https://search.softdigi.example/search`.
///
/// Intentionally not a constant with a default value: this app ships with no
/// search endpoint baked in. To enable Web Search in a build, pass it at
/// build time:
///
/// ```
/// flutter build apk --release --dart-define=SEARXNG_ENDPOINT=https://search.softdigi.example/search
/// ```
///
/// Without it, [WebSearchService.isConfigured] is false and the app behaves
/// exactly as it does today: Local Only and Smart mode never see a working
/// "Allow" path, and no network code ever runs.
const String searxngEndpointFromBuild = String.fromEnvironment(
  'SEARXNG_ENDPOINT',
);
