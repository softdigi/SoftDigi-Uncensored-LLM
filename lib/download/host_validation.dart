/// Which hosts the Download Center may fetch model files from, or be
/// redirected to. Hugging Face serves the actual bytes from CDN subdomains
/// (for example `us.aws.cdn.hf.co` or `cdn-lfs.huggingface.co`) after a
/// redirect away from `huggingface.co` — so subdomains of both approved
/// domains are allowed, but nothing else. [DownloadManager] checks this
/// against the initial URL and every redirect hop; it never follows a
/// redirect to an unapproved host.
bool isApprovedModelHost(Uri uri) {
  if (uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  const exact = {'huggingface.co', 'hf.co'};
  const suffixes = ['.huggingface.co', '.hf.co'];
  if (exact.contains(host)) return true;
  return suffixes.any(host.endsWith);
}

/// Thrown when a URL — initial or a redirect target — is not on an approved
/// model host. The download stops immediately; it never follows the redirect.
class HostNotApprovedException implements Exception {
  const HostNotApprovedException(this.url);

  final String url;

  @override
  String toString() =>
      'blocked: "$url" is not on an approved model host (huggingface.co or hf.co)';
}

/// Validates [url] is HTTPS on an approved host and returns it parsed.
/// Throws [HostNotApprovedException] otherwise. Callers must also validate
/// every redirect hop with this same function — approving the first URL
/// does not approve where it redirects to.
Uri validatedModelUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !isApprovedModelHost(uri)) {
    throw HostNotApprovedException(url);
  }
  return uri;
}

/// Builds and validates the direct Hugging Face `resolve/main` URL for a
/// catalog entry's repo + file name. This is the only URL shape the Download
/// Center constructs itself.
Uri modelFileUrl({required String repo, required String fileName}) {
  return validatedModelUrl(
    'https://huggingface.co/$repo/resolve/main/${Uri.encodeComponent(fileName)}',
  );
}
