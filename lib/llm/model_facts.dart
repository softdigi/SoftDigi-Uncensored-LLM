/// Architecture facts read from a GGUF file's metadata by the native bridge.
/// Used by the memory estimator. Stored in the model registry.
class ModelFacts {
  const ModelFacts({
    required this.arch,
    required this.nLayer,
    required this.nHead,
    required this.nHeadKv,
    required this.nEmbd,
    required this.headDim,
    required this.nCtxTrain,
    required this.nVocab,
    required this.sizeBytes,
  });

  factory ModelFacts.fromJson(Map<String, Object?> json) => ModelFacts(
    arch: json['arch'] as String,
    nLayer: json['nLayer'] as int,
    nHead: json['nHead'] as int,
    nHeadKv: json['nHeadKv'] as int,
    nEmbd: json['nEmbd'] as int,
    headDim: json['headDim'] as int,
    nCtxTrain: json['nCtxTrain'] as int,
    nVocab: json['nVocab'] as int,
    sizeBytes: json['sizeBytes'] as int,
  );

  final String arch;
  final int nLayer;
  final int nHead;
  final int nHeadKv;
  final int nEmbd;
  final int headDim;
  final int nCtxTrain;
  final int nVocab;

  /// Size of the weight data as reported by llama.cpp.
  final int sizeBytes;

  Map<String, Object?> toJson() => {
    'arch': arch,
    'nLayer': nLayer,
    'nHead': nHead,
    'nHeadKv': nHeadKv,
    'nEmbd': nEmbd,
    'headDim': headDim,
    'nCtxTrain': nCtxTrain,
    'nVocab': nVocab,
    'sizeBytes': sizeBytes,
  };

  @override
  String toString() =>
      '$arch: $nLayer layers, $nHeadKv KV heads, head dim $headDim, '
      'train ctx $nCtxTrain, vocab $nVocab';
}
