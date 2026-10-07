import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../chat/chat_session.dart';
import '../chat/chat_store.dart';
import '../chat/context_manager.dart';
import '../llm/chat_prompt.dart';
import '../llm/llm_worker.dart';
import '../models/model_importer.dart';
import '../models/model_manager.dart';
import '../models/model_profile.dart';
import '../models/model_registry.dart';
import '../models/model_runtime.dart';
import '../models/thermal_policy.dart';

/// One message shown in the chat list.
class ChatBubble {
  ChatBubble({required this.isUser, this.text = '', this.streaming = false});

  final bool isUser;
  String text;
  bool streaming;

  /// Set when generating this reply failed. The bubble shows the reason.
  String? error;
}

/// Whether the open conversation can accept a new message.
enum ChatAccess {
  /// No conversation is open; the next message starts one.
  newChat,

  /// The conversation's model is loaded.
  ready,

  /// The model exists but is not loaded. The user must load it to continue.
  needsLoad,

  /// The model is no longer installed. The chat can be read but not continued.
  modelMissing,
}

/// App state and actions. The UI reads this and calls its methods.
///
/// Inference never runs on the UI isolate. Every model call goes through
/// [ModelRuntime], which is backed by the LlmWorker isolate. Chat history is
/// saved locally through [ChatStore].
class AppController extends ChangeNotifier {
  AppController({
    required this.manager,
    required this.runtime,
    required this.importer,
    required this.store,
    required this.suggestedThreads,
  });

  final ModelManager manager;
  final ModelRuntime runtime;
  final ModelImporter importer;
  final ChatStore store;

  /// Thread count from the worker, read once at startup.
  final int suggestedThreads;

  /// Messages of the open conversation, for display.
  final List<ChatBubble> messages = [];

  /// The open conversation, or null when a new chat has not started yet.
  Conversation? _current;

  ChatSession? _session;
  bool _busy = false;
  bool _generating = false;
  String? _busyMessage;
  String? _errorMessage;
  String? _notice;

  bool get busy => _busy;
  bool get generating => _generating;
  String? get busyMessage => _busyMessage;
  String? get errorMessage => _errorMessage;
  String? get notice => _notice;

  List<InstalledModel> get models => manager.models;
  bool get hasModels => manager.models.isNotEmpty;
  InstalledModel? get loadedModel => manager.active;
  int? get loadedContextTokens => manager.activeContextTokens;
  bool get canChat => loadedModel != null && _session != null;

  /// Id of the open conversation, if it has been saved.
  String? get currentConversationId => _current?.id;

  ModelProfile? get loadedProfile {
    final m = loadedModel;
    return m == null ? null : profileById(m.profileId);
  }

  /// Saved conversations, most recently updated first.
  List<Conversation> get history => store.listAll();

  /// Name of the model a conversation belongs to, or null if that model is gone.
  String? modelNameFor(String modelId) => manager.byId(modelId)?.displayName;

  ChatAccess get access {
    final c = _current;
    if (c == null) return ChatAccess.newChat;
    if (loadedModel?.id == c.modelId && _session != null) {
      return ChatAccess.ready;
    }
    if (manager.byId(c.modelId) == null) return ChatAccess.modelMissing;
    return ChatAccess.needsLoad;
  }

  /// Name of the model the open conversation needs, for display.
  String? get requiredModelName =>
      _current == null ? null : modelNameFor(_current!.modelId);

  void dismissError() {
    _errorMessage = null;
    notifyListeners();
  }

  void dismissNotice() {
    _notice = null;
    notifyListeners();
  }

  void _setBusy(String message) {
    _busy = true;
    _busyMessage = message;
    _errorMessage = null;
    notifyListeners();
  }

  void _clearBusy() {
    _busy = false;
    _busyMessage = null;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  ChatSession _newSession(ModelProfile profile, int contextTokens) {
    return ChatSession(
      profile: profile,
      runtime: runtime,
      contextTokens: contextTokens,
      suggestedThreads: suggestedThreads,
      thermal: () async =>
          thermalLevelFromCode(await importer.thermalStatusCode()),
      unloadActive: unloadModel,
    );
  }

  /// Restores the open conversation's messages into the session, so the model
  /// continues the same conversation.
  void _restoreTranscript(ChatSession session, Conversation c) {
    for (final m in c.messages) {
      session.transcript.add(
        ChatMessage(m.isUser ? ChatRole.user : ChatRole.assistant, m.text),
      );
    }
  }

  void _showMessages(Conversation? c) {
    messages
      ..clear()
      ..addAll([
        if (c != null)
          for (final m in c.messages)
            ChatBubble(isUser: m.isUser, text: m.text)..error = m.error,
      ]);
  }

  /// Saves the open conversation. A failed save is reported, and the chat stays open.
  void _save() {
    final c = _current;
    if (c == null) return;
    try {
      store.save(c);
    } catch (_) {
      _fail('Could not save this chat. Check that the phone has free storage.');
    }
  }

  /// Opens the system file picker, copies the file into private storage, validates it
  /// and registers it under [profile].
  Future<void> importModel(ModelProfile profile) async {
    if (_busy || _generating) return _fail('Finish the current task first.');
    _setBusy('Copying model into private storage…');
    try {
      final picked = await importer.pickAndCopy();
      if (picked == null) return;
      _busyMessage = 'Reading model information…';
      notifyListeners();
      final model = await manager.registerFile(
        fileName: picked.fileName,
        displayName: _nameFrom(picked.displayName),
        profile: profile,
      );
      _notice = '${model.displayName} was added to your models.';
    } on PlatformException catch (e) {
      _fail(
        e.code == 'bad_header'
            ? 'That file is not a GGUF model. Choose a .gguf model file.'
            : 'The file could not be imported. Please try again.',
      );
    } on ModelManagerException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('The file could not be imported. Please try again.');
    } finally {
      _clearBusy();
    }
  }

  static String _nameFrom(String fileName) {
    final base = fileName.replaceAll(
      RegExp(r'\.gguf$', caseSensitive: false),
      '',
    );
    return base.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  }

  /// Loads [id] (or switches to it). Only one model stays in memory.
  ///
  /// Switching to a different model starts a new chat. The previous chat stays in
  /// history. Loading the model that the open chat belongs to keeps that chat.
  Future<void> loadModel(String id) async {
    if (_generating) return _fail('Stop the reply before switching models.');
    if (_busy) return;
    final model = manager.byId(id);
    if (model == null) return;
    final profile = profileById(model.profileId) ?? chatProfile;
    final previous = loadedModel;
    final keepChat = _current != null && _current!.modelId == id;
    _setBusy(
      previous == null
          ? 'Loading ${model.displayName}…'
          : 'Switching to ${model.displayName}…',
    );
    try {
      final report = await manager.activate(id, profile: profile);
      if (!keepChat) {
        _current = null;
        messages.clear();
      }
      _session = _newSession(profile, report.contextTokens);
      if (keepChat) _restoreTranscript(_session!, _current!);
      final seconds = (report.loadMs / 1000).toStringAsFixed(1);
      _notice =
          'Loaded ${model.displayName} in $seconds s'
          '${report.contextClamped ? '. Context reduced to ${report.contextTokens} tokens to fit memory' : ''}.';
    } on ModelManagerException catch (e) {
      _session = null;
      _fail(e.message);
    } catch (_) {
      _session = null;
      _fail(
        'This model could not be loaded. The file may be damaged or unsupported.',
      );
    } finally {
      _clearBusy();
    }
  }

  /// Frees the loaded model. A running reply is stopped first.
  Future<void> unloadModel() async {
    if (_generating) stopGeneration();
    _session = null;
    await manager.deactivate();
    notifyListeners();
  }

  /// Starts a new chat with the loaded model. Earlier chats stay in history.
  void newChat() {
    if (_generating) return _fail('Stop the reply before starting a new chat.');
    _current = null;
    messages.clear();
    final profile = loadedProfile;
    final context = loadedContextTokens;
    if (profile != null && context != null) {
      _session = _newSession(profile, context);
    }
    notifyListeners();
  }

  /// Opens a saved conversation. It is shown in full. It can be continued only when
  /// its model is loaded. The controller never loads a model silently.
  void openConversation(String id) {
    if (_generating) {
      return _fail('Stop the reply before opening another chat.');
    }
    final c = store.get(id);
    if (c == null) return _fail('That chat could not be opened.');
    _current = c;
    _showMessages(c);
    final profile = profileById(c.profileId) ?? chatProfile;
    final context = loadedContextTokens;
    if (loadedModel?.id == c.modelId && context != null) {
      _session = _newSession(loadedProfile ?? profile, context);
      _restoreTranscript(_session!, c);
    } else {
      _session = null;
    }
    notifyListeners();
  }

  /// Deletes one saved chat. Models and other data are not affected.
  void deleteConversation(String id) {
    if (_generating && _current?.id == id) {
      return _fail('Stop the reply before deleting this chat.');
    }
    try {
      store.delete(id);
    } catch (_) {
      return _fail('The chat could not be deleted. Please try again.');
    }
    if (_current?.id == id) newChat();
    notifyListeners();
  }

  /// Deletes every saved chat. Models and other data are not affected.
  void deleteAllConversations() {
    if (_generating) return _fail('Stop the reply before deleting chats.');
    try {
      store.deleteAll();
    } catch (_) {
      return _fail('The chats could not be deleted. Please try again.');
    }
    newChat();
    _notice = 'All chat history was deleted.';
    notifyListeners();
  }

  Future<void> deleteModel(String id) async {
    if (_generating) return _fail('Stop the reply before deleting a model.');
    if (_busy) return;
    final name = manager.byId(id)?.displayName ?? 'Model';
    if (loadedModel?.id == id) {
      _session = null;
    }
    await manager.delete(id);
    _notice = '$name was deleted from this phone.';
    notifyListeners();
  }

  void setUse(String id, ModelProfile profile) {
    if (_generating) return _fail('Stop the reply before changing a model.');
    manager.setProfile(id, profile);
    notifyListeners();
  }

  void clearQuarantine(String id) {
    manager.clearQuarantine(id);
    notifyListeners();
  }

  /// Sends [raw] and streams the reply into the chat. Both messages are saved locally
  /// when the reply ends, including when it is stopped.
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _generating || _busy) return;
    final session = _session;
    final model = loadedModel;
    if (access == ChatAccess.needsLoad) {
      return _fail(
        'Load ${requiredModelName ?? 'the model'} to continue this chat.',
      );
    }
    if (access == ChatAccess.modelMissing) {
      return _fail(
        'The model for this chat is no longer installed. Start a new chat to continue.',
      );
    }
    if (session == null || model == null) {
      return _fail('Load a model to start chatting.');
    }

    _errorMessage = null;
    final now = DateTime.now();
    _current ??= Conversation(
      id: 'c${now.microsecondsSinceEpoch}',
      modelId: model.id,
      profileId: loadedProfile?.id ?? chatProfile.id,
      createdAt: now,
      updatedAt: now,
    );
    _current!.messages.add(
      StoredMessage(isUser: true, text: text, createdAt: now),
    );
    _current!.updatedAt = now;
    _save();

    final userBubble = ChatBubble(isUser: true, text: text);
    final reply = ChatBubble(isUser: false, streaming: true);
    messages
      ..add(userBubble)
      ..add(reply);
    _generating = true;
    notifyListeners();

    try {
      final level = thermalLevelFromCode(await importer.thermalStatusCode());
      final decision = decideThermal(
        level,
        suggestedThreads: suggestedThreads,
        requestedMaxTokens: session.profile.maxNewTokens,
      );
      if (decision.maxNewTokensCap != null || !decision.allowGeneration) {
        _notice = decision.message;
        notifyListeners();
      }

      await for (final event in session.send(text)) {
        if (event is LlmToken) {
          reply.text += event.text;
          notifyListeners();
        }
      }
      if (session.lastDroppedMessages > 0) {
        _notice =
            'Older messages were left out of this reply to fit the memory limit.';
      }
      if (reply.text.trim().isEmpty) {
        reply.error = 'No reply was produced. Try again.';
      }
    } on ContextTooLargeException catch (e) {
      reply.error = e.message;
    } on StateError catch (e) {
      reply.error = e.message.toString();
    } on LlmWorkerException catch (e) {
      reply.error = 'The model stopped responding: ${e.message}';
    } catch (e, st) {
      debugPrint('reply failed: $e\n$st');
      reply.error = 'Something went wrong. Please try again.';
    } finally {
      reply.streaming = false;
      _saveReply(reply);
      _generating = false;
      notifyListeners();
    }
  }

  /// Saves the assistant reply when it ends. Partial text from a stopped reply is kept.
  void _saveReply(ChatBubble reply) {
    final c = _current;
    if (c == null) return;
    if (reply.text.isEmpty && reply.error == null) return;
    final now = DateTime.now();
    c.messages.add(
      StoredMessage(
        isUser: false,
        text: reply.text,
        createdAt: now,
        error: reply.error,
      ),
    );
    c.updatedAt = now;
    _save();
  }

  /// Stops the reply being generated. The partial reply is kept and saved.
  void stopGeneration() {
    if (!_generating) return;
    runtime.stop();
  }
}
