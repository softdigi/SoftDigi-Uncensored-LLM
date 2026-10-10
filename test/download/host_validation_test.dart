import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/download/host_validation.dart';

void main() {
  group('isApprovedModelHost', () {
    test('accepts huggingface.co over https', () {
      expect(isApprovedModelHost(Uri.parse('https://huggingface.co/x')), isTrue);
    });

    test('accepts hf.co over https', () {
      expect(isApprovedModelHost(Uri.parse('https://hf.co/x')), isTrue);
    });

    test('accepts Hugging Face CDN subdomains', () {
      expect(
        isApprovedModelHost(Uri.parse('https://us.aws.cdn.hf.co/xet-bridge-us/x')),
        isTrue,
      );
      expect(
        isApprovedModelHost(Uri.parse('https://cdn-lfs-us-1.huggingface.co/x')),
        isTrue,
      );
    });

    test('rejects plain HTTP even on an approved host', () {
      expect(isApprovedModelHost(Uri.parse('http://huggingface.co/x')), isFalse);
    });

    test('rejects an unapproved host', () {
      expect(isApprovedModelHost(Uri.parse('https://evil.example.com/x')), isFalse);
    });

    test('rejects a lookalike host that merely contains the approved name', () {
      expect(
        isApprovedModelHost(Uri.parse('https://huggingface.co.evil.com/x')),
        isFalse,
      );
      expect(
        isApprovedModelHost(Uri.parse('https://nothuggingface.co/x')),
        isFalse,
      );
    });

    test('rejects an empty host', () {
      expect(isApprovedModelHost(Uri.parse('https:///x')), isFalse);
    });
  });

  group('validatedModelUrl', () {
    test('returns the parsed URI for an approved HTTPS host', () {
      final uri = validatedModelUrl('https://huggingface.co/x/resolve/main/y.gguf');
      expect(uri.host, 'huggingface.co');
    });

    test('throws HostNotApprovedException for an unapproved host', () {
      expect(
        () => validatedModelUrl('https://evil.example.com/y.gguf'),
        throwsA(isA<HostNotApprovedException>()),
      );
    });

    test('throws HostNotApprovedException for a malformed URL', () {
      expect(
        () => validatedModelUrl('not a url'),
        throwsA(isA<HostNotApprovedException>()),
      );
    });
  });

  group('modelFileUrl', () {
    test('builds the expected resolve/main URL', () {
      final uri = modelFileUrl(repo: 'org/Repo-GGUF', fileName: 'file-Q4_K_M.gguf');
      expect(
        uri.toString(),
        'https://huggingface.co/org/Repo-GGUF/resolve/main/file-Q4_K_M.gguf',
      );
    });
  });
}
