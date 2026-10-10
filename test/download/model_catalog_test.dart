import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/download/model_catalog.dart';
import 'package:soft_local_pai/models/model_profile.dart';

void main() {
  group('modelCatalog', () {
    test('has no duplicate entry ids', () {
      final ids = modelCatalog.map((e) => e.id).toSet();
      expect(ids.length, modelCatalog.length);
    });

    test('has at least one entry in every tier', () {
      for (final tier in ModelTier.values) {
        expect(
          modelCatalog.any((e) => e.tier == tier),
          isTrue,
          reason: 'no catalog entry for tier $tier',
        );
      }
    });

    test('has at least one uncensored entry', () {
      expect(
        modelCatalog.any((e) => e.intendedUse == ModelIntendedUse.uncensored),
        isTrue,
      );
    });

    test('has at least one uncensored entry that is actually compatible', () {
      expect(
        modelCatalog.any(
          (e) =>
              e.intendedUse == ModelIntendedUse.uncensored &&
              e.compatibility().isCompatible,
        ),
        isTrue,
        reason:
            'the catalog should not only offer uncensored models it refuses to run',
      );
    });

    test('every verified sha256 looks like a sha256 (64 hex chars)', () {
      final hex = RegExp(r'^[0-9a-f]{64}$');
      for (final e in modelCatalog) {
        expect(
          hex.hasMatch(e.verifiedSha256),
          isTrue,
          reason: '${e.id} has a malformed verifiedSha256',
        );
      }
    });

    test('every entry\'s profile is reachable through profileById', () {
      for (final e in modelCatalog) {
        expect(
          profileById(e.profile.id),
          same(e.profile),
          reason: '${e.id}\'s profile is not registered in allProfiles',
        );
      }
    });

    test('small models are compatible on the 8 GB planning budget', () {
      for (final e in modelCatalog.where((e) => e.tier == ModelTier.small)) {
        expect(
          e.compatibility().isCompatible,
          isTrue,
          reason: '${e.id} is tier small but the estimator refuses it',
        );
      }
    });

    test('the 14B model is not claimed compatible on this device', () {
      final e = modelCatalog.firstWhere((e) => e.id == 'qwen25-14b-q4km');
      expect(e.compatibility().isCompatible, isFalse);
    });

    test(
      'the Q4_K_M 7B entry is incompatible but its IQ3_M sibling is compatible',
      () {
        final q4 = modelCatalog.firstWhere((e) => e.id == 'qwen25-7b-q4km');
        final iq3 = modelCatalog.firstWhere((e) => e.id == 'qwen25-7b-iq3m');
        expect(q4.compatibility().isCompatible, isFalse);
        expect(iq3.compatibility().isCompatible, isTrue);
      },
    );

    test(
      'the DavidAU Qwen3.5-9B entry is never claimed compatible or runnable',
      () {
        final e = modelCatalog.firstWhere(
          (e) => e.id == 'davidau-qwen35-9b-defiant-fable-iq2m',
        );
        final result = e.compatibility();
        expect(result.isCompatible, isFalse);
        expect(
          result.verdict,
          CatalogCompatibility.incompatibleBySizeAlone,
        );
        expect(e.testedOnDevice, isFalse);
      },
    );

    test('no entry claims to be tested on device unless it genuinely was', () {
      // Only the one model this project's QA pass actually ran real
      // inference with on a physical device may claim this.
      final tested = modelCatalog.where((e) => e.testedOnDevice).toList();
      expect(tested.map((e) => e.id), ['qwen25-coder-1.5b-q4km']);
    });
  });
}
