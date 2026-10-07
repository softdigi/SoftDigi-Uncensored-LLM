import 'dart:convert';
import 'dart:io';

/// One message saved in a conversation.
class StoredMessage {
  const StoredMessage({
    required this.isUser,
    required this.text,
    required this.createdAt,
    this.error,
  });

  factory StoredMessage.fromJson(Map<String, Object?> json) => StoredMessage(
    isUser: json['role'] == 'user',
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    error: json['error'] as String?,
  );

  final bool isUser;
  final String text;
  final DateTime createdAt;

  /// Set when the reply failed. The partial text, if any, is still kept.
  final String? error;

  Map<String, Object?> toJson() => {
    'role': isUser ? 'user' : 'assistant',
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    if (error != null) 'error': error,
  };
}

/// A saved chat. Its model is referenced by id so the app can tell whether it is still installed.
class Conversation {
  Conversation({
    required this.id,
    required this.modelId,
    required this.profileId,
    required this.createdAt,
    required this.updatedAt,
    List<StoredMessage>? messages,
    String? title,
  }) : messages = messages ?? [],
       _title = title;

  factory Conversation.fromJson(Map<String, Object?> json) => Conversation(
    id: json['id'] as String,
    modelId: json['modelId'] as String,
    profileId: json['profileId'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    title: json['title'] as String?,
    messages: [
      for (final m in json['messages'] as List<Object?>)
        StoredMessage.fromJson((m as Map).cast<String, Object?>()),
    ],
  );

  final String id;
  final String modelId;
  final String profileId;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<StoredMessage> messages;
  final String? _title;

  /// Title from the first user message, or the saved title.
  String get title {
    if (_title != null && _title.isNotEmpty) return _title;
    for (final m in messages) {
      if (m.isUser) return _titleFrom(m.text);
    }
    return 'New chat';
  }

  static String _titleFrom(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 48) return oneLine;
    return '${oneLine.substring(0, 48).trimRight()}…';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'modelId': modelId,
    'profileId': profileId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
  };
}

/// Saves chat history as one JSON file per conversation under [dir].
///
/// Everything stays on this device. Writes go to a temporary file and are then
/// renamed, so an interrupted write cannot corrupt a saved conversation. Deleting
/// chats removes only files in [dir]; models and registry files are never touched.
class ChatStore {
  ChatStore(this.dir);

  final Directory dir;

  File _fileFor(String id) => File('${dir.path}/$id.json');

  /// All saved conversations, most recently updated first. Unreadable files are skipped.
  List<Conversation> listAll() {
    if (!dir.existsSync()) return [];
    final out = <Conversation>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(entity.readAsStringSync()) as Map<String, Object?>;
        out.add(Conversation.fromJson(json));
      } catch (_) {
        // A damaged file is left alone; it does not hide the other chats.
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Conversation? get(String id) {
    final f = _fileFor(id);
    if (!f.existsSync()) return null;
    try {
      return Conversation.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, Object?>,
      );
    } catch (_) {
      return null;
    }
  }

  void save(Conversation conversation) {
    dir.createSync(recursive: true);
    final target = _fileFor(conversation.id);
    final tmp = File('${target.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(conversation.toJson()), flush: true);
    tmp.renameSync(target.path);
  }

  void delete(String id) {
    final f = _fileFor(id);
    if (f.existsSync()) f.deleteSync();
  }

  /// Deletes every saved conversation. Other files in the app are not affected.
  void deleteAll() {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is File &&
          (entity.path.endsWith('.json') || entity.path.endsWith('.tmp'))) {
        entity.deleteSync();
      }
    }
  }
}
