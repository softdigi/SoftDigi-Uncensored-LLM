import '../llm/model_facts.dart';
import '../models/memory_estimator.dart';
import '../models/model_profile.dart';

/// Size bucket shown in the Download Center. Not a hard limit on parameter
/// count — it is how the catalog groups entries for the user.
enum ModelTier { small, medium, large }

/// What a model is meant for, shown next to it in the catalog.
enum ModelIntendedUse { chat, coding, reasoning, uncensored }

/// Verdict for whether [CatalogEntry.verifiedFacts] (when known) or raw file
/// size (when not) lets this model actually run under this app's existing
/// RAM policy (`MemoryPolicy` in memory_estimator.dart). This never weakens
/// or bypasses `MemoryGate` — it reuses the same `maxContextFor` the model
/// manager uses once a model is actually installed, so the catalog can only
/// ever be as permissive as the gate that runs at load time.
enum CatalogCompatibility {
  /// `maxContextFor` returns a usable context at the planning RAM budget.
  compatible,

  /// Facts are known and `maxContextFor` returns null: even the minimum
  /// context does not fit the planning budget.
  incompatible,

  /// Architecture-level facts for this exact file were not independently
  /// verified (see [CatalogEntry.verifiedFacts] == null), but the file's
  /// measured size alone already exceeds the budget once this app's fixed
  /// runtime overhead is added, before KV-cache or any margin — so it is
  /// shown as not compatible without needing the rest of the header.
  incompatibleBySizeAlone,
}

class CompatibilityResult {
  const CompatibilityResult({
    required this.verdict,
    required this.message,
    this.maxContextTokens,
    this.estimatedRamBytes,
  });

  final CatalogCompatibility verdict;
  final String message;
  final int? maxContextTokens;
  final int? estimatedRamBytes;

  bool get isCompatible => verdict == CatalogCompatibility.compatible;
}

/// One downloadable file offered in the Download Center.
///
/// Every number on this class was measured from the real Hugging Face file
/// during development (HTTP HEAD for size, the `X-Linked-ETag` header for
/// sha256, and the model publisher's own `config.json` for architecture
/// hparams) — none of it is invented. [verifiedFacts] is a snapshot taken at
/// that time, not a live source of truth: [DownloadManager] always re-checks
/// the real size and host before a download starts, and a size that drifts
/// from [verifiedFacts] by more than a small tolerance blocks the download
/// rather than silently trusting either number.
class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.displayName,
    required this.publisher,
    required this.repo,
    required this.fileName,
    required this.quantization,
    required this.tier,
    required this.intendedUse,
    required this.license,
    required this.licenseNotes,
    required this.parameterCountLabel,
    required this.verifiedFacts,
    required this.verifiedSizeBytes,
    required this.verifiedSha256,
    required this.profile,
    required this.testedOnDevice,
    this.compatibilityNote,
  });

  /// Stable id for this catalog entry (not the installed-model id).
  final String id;

  final String displayName;
  final String publisher;

  /// Hugging Face repo, e.g. "bartowski/Llama-3.2-3B-Instruct-GGUF".
  final String repo;

  /// Exact file name inside [repo].
  final String fileName;

  final String quantization;
  final ModelTier tier;
  final ModelIntendedUse intendedUse;

  /// Parameter count as stated by the publisher (e.g. "~7B"). Shown as-is
  /// rather than computed, except where noted that it was not independently
  /// re-verified.
  final String parameterCountLabel;

  /// License as stated by the publisher (repo tag or card), verified at
  /// catalog-build time, not inferred.
  final String license;

  /// Caveats about licensing or redistribution the user should see before
  /// downloading (e.g. "inherits Meta's Llama Community License and
  /// acceptable-use policy", "base model's own license not independently
  /// confirmed").
  final String licenseNotes;

  /// Architecture facts read from the publisher's own `config.json` (for
  /// standard architectures) or confirmed GGUF tag metadata, at the time this
  /// catalog was written. Null when the exact header was not independently
  /// re-derived for this file (currently only the DavidAU entry) — in that
  /// case compatibility falls back to [CatalogCompatibility.incompatibleBySizeAlone].
  final ModelFacts? verifiedFacts;

  /// Exact byte size measured via HTTP HEAD / `X-Linked-Size` at the time
  /// this catalog was written. [DownloadManager] always re-verifies this
  /// live before downloading; this value is the baseline it compares against.
  final int verifiedSizeBytes;

  /// sha256 of the file, read from Hugging Face's `X-Linked-ETag` header
  /// (its git-lfs content hash) at the time this catalog was written. Used
  /// to verify integrity after download.
  final String verifiedSha256;

  /// Profile this model is registered under once downloaded — carries the
  /// correct model identity (never the two built-in profiles' names) and the
  /// chat template verified for this specific file.
  final ModelProfile profile;

  /// Whether this exact file has been loaded and used for real inference on
  /// a physical device during this app's development. False is the honest
  /// default — most catalog entries have not been.
  final bool testedOnDevice;

  /// Extra human-readable note shown with the compatibility status, e.g. why
  /// a technically-loadable architecture still doesn't fit this device.
  final String? compatibilityNote;

  /// Compatibility with this app's fixed 8 GB planning budget, independent of
  /// how much RAM happens to be free right now (that live check happens again,
  /// unchanged, in `ModelManager.activate` when the user actually loads it).
  CompatibilityResult compatibility() {
    final facts = verifiedFacts;
    if (facts == null) {
      final tooLargeBySizeAlone =
          verifiedSizeBytes + MemoryPolicy.runtimeOverheadBytes >
          MemoryPolicy.budgetBytes;
      if (tooLargeBySizeAlone) {
        return CompatibilityResult(
          verdict: CatalogCompatibility.incompatibleBySizeAlone,
          message:
              'Not compatible on this device: the file itself '
              '(${(verifiedSizeBytes / mib).round()} MB) plus this app\'s fixed runtime '
              'overhead already exceeds the memory budget, before KV-cache or any safety '
              'margin is added.',
        );
      }
      return const CompatibilityResult(
        verdict: CatalogCompatibility.incompatibleBySizeAlone,
        message:
            'Architecture details for this exact file were not independently verified; '
            'shown as experimental.',
      );
    }
    final maxCtx = maxContextFor(facts);
    if (maxCtx == null) {
      return CompatibilityResult(
        verdict: CatalogCompatibility.incompatible,
        message:
            'Not compatible on this device: even the minimum '
            '${MemoryPolicy.minContextTokens}-token context does not fit the '
            '${MemoryPolicy.budgetBytes ~/ mib} MB memory budget.',
      );
    }
    final estimate = estimateMemory(facts, maxCtx);
    return CompatibilityResult(
      verdict: CatalogCompatibility.compatible,
      message:
          'Compatible: up to $maxCtx tokens of context, about '
          '${(estimate.total / mib).round()} MB RAM.',
      maxContextTokens: maxCtx,
      estimatedRamBytes: estimate.total,
    );
  }
}

/// The curated starter catalog. Every entry was individually verified
/// (real file size, real sha256, publisher's own published hparams or GGUF
/// tags, and — for the DavidAU model — the pinned llama.cpp fork's actual
/// architecture support) before being added here. See the project's design
/// notes for the full verification trail; nothing here is a guess.
const List<CatalogEntry> modelCatalog = [
  // ---- Small (compatible) ----
  CatalogEntry(
    id: 'llama32-3b-q4km',
    displayName: 'Llama 3.2 3B Instruct',
    publisher: 'Meta (quantized by bartowski)',
    repo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.small,
    intendedUse: ModelIntendedUse.chat,
    parameterCountLabel: '~3B',
    license: 'Llama 3.2 Community License (Meta)',
    licenseNotes:
        'Meta\'s license, not Apache: includes an acceptable-use policy and a separate '
        'license requirement for services with over 700M monthly active users. Attribution '
        '("Built with Llama") is required on redistribution.',
    verifiedFacts: ModelFacts(
      arch: 'llama',
      nLayer: 28,
      nHead: 24,
      nHeadKv: 8,
      nEmbd: 3072,
      headDim: 128,
      nCtxTrain: 131072,
      nVocab: 128256,
      sizeBytes: 2019377696,
    ),
    verifiedSizeBytes: 2019377696,
    verifiedSha256:
        '6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff',
    profile: chatProfile,
    testedOnDevice: false,
    compatibilityNote:
        'Gate-refusal has been confirmed on a physical device under memory pressure; a '
        'successful load of this exact file has not yet been confirmed on-device.',
  ),
  CatalogEntry(
    id: 'qwen25-coder-1.5b-q4km',
    displayName: 'Qwen2.5-Coder 1.5B Instruct',
    publisher: 'Alibaba Cloud (Qwen team)',
    repo: 'Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF',
    fileName: 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.small,
    intendedUse: ModelIntendedUse.coding,
    parameterCountLabel: '~1.5B',
    license: 'Apache License 2.0',
    licenseNotes: 'Permissive; no additional use restrictions found.',
    verifiedFacts: ModelFacts(
      arch: 'qwen2',
      nLayer: 28,
      nHead: 12,
      nHeadKv: 2,
      nEmbd: 1536,
      headDim: 128,
      nCtxTrain: 32768,
      nVocab: 151936,
      sizeBytes: 1117320768,
    ),
    verifiedSizeBytes: 1117320768,
    verifiedSha256:
        'cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046',
    profile: codingProfile,
    testedOnDevice: true,
    compatibilityNote: 'Loaded and used for real inference on a physical device.',
  ),
  CatalogEntry(
    id: 'qwen25-coder-3b-q4km',
    displayName: 'Qwen2.5-Coder 3B Instruct',
    publisher: 'Alibaba Cloud (Qwen team)',
    repo: 'Qwen/Qwen2.5-Coder-3B-Instruct-GGUF',
    fileName: 'qwen2.5-coder-3b-instruct-q4_k_m.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.small,
    intendedUse: ModelIntendedUse.coding,
    parameterCountLabel: '~3B',
    license: 'Apache License 2.0',
    licenseNotes: 'Permissive; no additional use restrictions found.',
    verifiedFacts: ModelFacts(
      arch: 'qwen2',
      nLayer: 36,
      nHead: 16,
      nHeadKv: 2,
      nEmbd: 2048,
      headDim: 128,
      nCtxTrain: 32768,
      nVocab: 151936,
      sizeBytes: 2104932800,
    ),
    verifiedSizeBytes: 2104932800,
    verifiedSha256:
        '724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7',
    profile: codingQwenCoder3bProfile,
    testedOnDevice: false,
  ),

  // ---- Uncensored, small (compatible) ----
  CatalogEntry(
    id: 'llama32-3b-uncensored-q4km',
    displayName: 'Llama 3.2 3B Instruct (uncensored)',
    publisher: 'chuanli11 (quantized by bartowski)',
    repo: 'bartowski/Llama-3.2-3B-Instruct-uncensored-GGUF',
    fileName: 'Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.small,
    intendedUse: ModelIntendedUse.uncensored,
    parameterCountLabel: '~3B',
    license: 'Llama 3.2 Community License (Meta) — inherited from the base model',
    licenseNotes:
        'This fine-tune\'s own repo does not restate a separate license tag; as a '
        'derivative of Meta\'s Llama 3.2 3B Instruct it carries the same community license '
        'and acceptable-use policy as the base model.',
    verifiedFacts: ModelFacts(
      arch: 'llama',
      nLayer: 28,
      nHead: 24,
      nHeadKv: 8,
      nEmbd: 3072,
      headDim: 128,
      nCtxTrain: 131072,
      nVocab: 128256,
      sizeBytes: 2241003904,
    ),
    verifiedSizeBytes: 2241003904,
    verifiedSha256:
        '80f532552e3d56e366226f428395de8285a671f2da1d5fd68563741181b77a95',
    profile: uncensoredLlama32_3bProfile,
    testedOnDevice: false,
  ),

  // ---- Medium ----
  CatalogEntry(
    id: 'qwen25-7b-q4km',
    displayName: 'Qwen2.5-7B Instruct',
    publisher: 'Alibaba Cloud (Qwen team) (quantized by bartowski)',
    repo: 'bartowski/Qwen2.5-7B-Instruct-GGUF',
    fileName: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.medium,
    intendedUse: ModelIntendedUse.reasoning,
    parameterCountLabel: '~7B',
    license: 'Apache License 2.0',
    licenseNotes: 'Permissive; no additional use restrictions found.',
    verifiedFacts: ModelFacts(
      arch: 'qwen2',
      nLayer: 28,
      nHead: 28,
      nHeadKv: 4,
      nEmbd: 3584,
      headDim: 128,
      nCtxTrain: 32768,
      nVocab: 152064,
      sizeBytes: 4683074240,
    ),
    verifiedSizeBytes: 4683074240,
    verifiedSha256:
        '65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423',
    profile: qwen25_7bProfile,
    testedOnDevice: false,
    compatibilityNote:
        'Shown for comparison: at Q4_K_M this does not fit the memory budget on this '
        'device. The IQ3_M quantization of the same model below does, at reduced quality.',
  ),
  CatalogEntry(
    id: 'qwen25-7b-iq3m',
    displayName: 'Qwen2.5-7B Instruct (lower-quality, fits this device)',
    publisher: 'Alibaba Cloud (Qwen team) (quantized by bartowski)',
    repo: 'bartowski/Qwen2.5-7B-Instruct-GGUF',
    fileName: 'Qwen2.5-7B-Instruct-IQ3_M.gguf',
    quantization: 'IQ3_M',
    tier: ModelTier.medium,
    intendedUse: ModelIntendedUse.reasoning,
    parameterCountLabel: '~7B',
    license: 'Apache License 2.0',
    licenseNotes: 'Permissive; no additional use restrictions found.',
    verifiedFacts: ModelFacts(
      arch: 'qwen2',
      nLayer: 28,
      nHead: 28,
      nHeadKv: 4,
      nEmbd: 3584,
      headDim: 128,
      nCtxTrain: 32768,
      nVocab: 152064,
      sizeBytes: 3574012608,
    ),
    verifiedSizeBytes: 3574012608,
    verifiedSha256:
        'e8fe0f85ecaac12c9270b0ecad6f04f4da714a2e1ee6fb5a8d787f9c4934baab',
    profile: qwen25_7bProfile,
    testedOnDevice: false,
    compatibilityNote:
        'Fits only with a tight margin, near the minimum context, and at visibly reduced '
        'quality compared with Q4_K_M. Treat as the ceiling of what a 7B model can do on '
        'this device, not a recommendation over the 1.5B/3B models above.',
  ),

  // ---- Large (not compatible on this device; shown for transparency) ----
  CatalogEntry(
    id: 'qwen25-14b-q4km',
    displayName: 'Qwen2.5-14B Instruct',
    publisher: 'Alibaba Cloud (Qwen team) (quantized by bartowski)',
    repo: 'bartowski/Qwen2.5-14B-Instruct-GGUF',
    fileName: 'Qwen2.5-14B-Instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.large,
    intendedUse: ModelIntendedUse.reasoning,
    parameterCountLabel: '~14B',
    license: 'Apache License 2.0',
    licenseNotes: 'Permissive; no additional use restrictions found.',
    verifiedFacts: ModelFacts(
      arch: 'qwen2',
      nLayer: 48,
      nHead: 40,
      nHeadKv: 8,
      nEmbd: 5120,
      headDim: 128,
      nCtxTrain: 32768,
      nVocab: 152064,
      sizeBytes: 8988110976,
    ),
    verifiedSizeBytes: 8988110976,
    verifiedSha256:
        'e47ad95dad6ff848b431053b375adb5d39321290ea2c638682577dafca87c008',
    profile: qwen25_14bProfile,
    testedOnDevice: false,
    compatibilityNote:
        'Included so it can be inspected, not because it is expected to run here: at '
        '8.4 GB the weights alone are larger than the entire 4.8 GB planning budget.',
  ),
  CatalogEntry(
    id: 'lexi-8b-uncensored-q4km',
    displayName: 'Llama 3.1 8B Lexi Uncensored V2',
    publisher: 'Orenguteng (quantized by bartowski)',
    repo: 'bartowski/Llama-3.1-8B-Lexi-Uncensored-V2-GGUF',
    fileName: 'Llama-3.1-8B-Lexi-Uncensored-V2-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    tier: ModelTier.large,
    intendedUse: ModelIntendedUse.uncensored,
    parameterCountLabel: '~8B',
    license: 'Llama 3.1 Community License (Meta)',
    licenseNotes:
        'Explicitly tagged license:llama3.1 by the publisher. Includes Meta\'s '
        'acceptable-use policy and the 700M-MAU clause, same as the base model.',
    verifiedFacts: ModelFacts(
      arch: 'llama',
      nLayer: 32,
      nHead: 32,
      nHeadKv: 8,
      nEmbd: 4096,
      headDim: 128,
      nCtxTrain: 131072,
      nVocab: 128256,
      sizeBytes: 4920739104,
    ),
    verifiedSizeBytes: 4920739104,
    verifiedSha256:
        '376ac398dc4542c4bd29b679b9f63f4988f0c032b327cadbe82909cd8eb12539',
    profile: uncensoredLexi8bProfile,
    testedOnDevice: false,
    compatibilityNote:
        'This was the first alternative investigated to the DavidAU 9B model below. It is '
        'architecturally identical to the already-working Llama 3.2 3B family, but at 8B '
        'and Q4_K_M it still does not fit this device\'s memory budget.',
  ),

  // ---- Uncensored, large / experimental ----
  CatalogEntry(
    id: 'davidau-qwen35-9b-defiant-fable-iq2m',
    displayName: 'Qwen3.5-9B The Defiant Fable (Uncensored/Heretic)',
    publisher: 'DavidAU, from Qwen3.5-9B (Alibaba Cloud)',
    repo:
        'DavidAU/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-IMATRIX-MAX-MTP-GGUF',
    fileName: 'Qwen3.5-9B-The-Defiant-Fable-Uncnr-Heretic-NEO-MAX-IQ2_M.gguf',
    quantization: 'IQ2_M (plain, non-MTP file — see note)',
    tier: ModelTier.large,
    intendedUse: ModelIntendedUse.uncensored,
    parameterCountLabel: '~9B (publisher-stated; not independently recomputed)',
    license: 'Apache License 2.0 (repo tag)',
    licenseNotes:
        'The repo is tagged apache-2.0. Qwen3.5 upstream checkpoints are widely reported '
        'as Apache-2.0, but this was not confirmed from Qwen\'s own primary LICENSE file '
        'during this review — check it before relying on this for redistribution.',
    verifiedFacts: null,
    verifiedSizeBytes: 4942441760,
    verifiedSha256:
        'ae9679dee69a4cb3a9375efa3644adc0164a362c61df2b283696d05e57df2fca',
    profile: uncensoredQwen35_9bProfile,
    testedOnDevice: false,
    compatibilityNote:
        'This is the model investigated at the user\'s request. The "qwen35" architecture, '
        'including its NextN/MTP tensors, is genuinely supported by the pinned llama.cpp '
        'fork (src/models/qwen35.cpp) — MTP tensors are skipped at load (load_mtp defaults '
        'to false), so the plain file above is used instead of the larger "-MTP-" files, '
        'which would only add dead weight. But every quantization in this repo, including '
        'this smallest one (IQ2_M, already noticeably lower quality than Q4_K_M), measures '
        'larger than this device\'s memory budget allows. It is shown here as experimental, '
        'not as a recommended or verified-runnable model, and the app\'s memory estimator '
        'will refuse to load it exactly as it would any other oversized model.',
  ),
];
