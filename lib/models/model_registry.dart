import 'dart:convert';
import 'dart:io';

import '../llm/model_facts.dart';

/// One GGUF file in the app's private models folder, with its metadata.
class InstalledModel {
  const InstalledModel({
    required this.id,
    required this.profileId,
    required this.displayName,
    required this.fileName,
    required this.sizeBytes,
    required this.importedAt,
    required this.facts,
    this.quarantineReason,
  });

  factory InstalledModel.fromJson(Map<String, Object?> json) => InstalledModel(
    id: json['id'] as String,
    profileId: json['profileId'] as String,
    displayName: json['displayName'] as String,
    fileName: json['fileName'] as String,
    sizeBytes: json['sizeBytes'] as int,
    importedAt: DateTime.parse(json['importedAt'] as String),
    facts: ModelFacts.fromJson((json['facts'] as Map).cast<String, Object?>()),
    quarantineReason: json['quarantineReason'] as String?,
  );

  final String id;
  final String profileId;
  final String displayName;

  /// File name inside the models folder (not a path).
  final String fileName;
  final int sizeBytes;
  final DateTime importedAt;
  final ModelFacts facts;

  /// Set when a previous load of this model did not finish (see CrashMarker).
  /// A quarantined model is not loaded until the user clears the flag.
  final String? quarantineReason;

  bool get isQuarantined => quarantineReason != null;

  InstalledModel copyWith({
    String? profileId,
    String? quarantineReason,
    bool clearQuarantine = false,
  }) => InstalledModel(
    id: id,
    profileId: profileId ?? this.profileId,
    displayName: displayName,
    fileName: fileName,
    sizeBytes: sizeBytes,
    importedAt: importedAt,
    facts: facts,
    quarantineReason: clearQuarantine
        ? null
        : (quarantineReason ?? this.quarantineReason),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'profileId': profileId,
    'displayName': displayName,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'importedAt': importedAt.toIso8601String(),
    'facts': facts.toJson(),
    'quarantineReason': quarantineReason,
  };
}

/// Reads and writes registry.json. Writes go to a temporary file first, then
/// rename, so a crash cannot leave a half-written registry.
class ModelRegistryStore {
  ModelRegistryStore(this.file);

  final File file;

  List<InstalledModel> read() {
    if (!file.existsSync()) return [];
    final raw = jsonDecode(file.readAsStringSync()) as List<Object?>;
    return [
      for (final e in raw)
        InstalledModel.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  void write(List<InstalledModel> models) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert([for (final m in models) m.toJson()]),
      flush: true,
    );
    tmp.renameSync(file.path);
  }
}
