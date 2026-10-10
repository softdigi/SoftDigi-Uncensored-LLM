import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/app/app_controller.dart';
import 'package:soft_local_pai/chat/chat_store.dart';
import 'package:soft_local_pai/llm/llm_worker.dart';
import 'package:soft_local_pai/models/model_importer.dart';
import 'package:soft_local_pai/models/model_manager.dart';
import 'package:soft_local_pai/models/model_profile.dart';
import 'package:soft_local_pai/search/search_settings_store.dart';

import '../models/fake_runtime.dart';
import '../search/fake_web_search_service.dart';

/// A runtime whose reply waits until the test calls [finish] or [stop].
/// Used to check a stopped reply keeps its partial text.
class SlowRuntime extends FakeRuntime {
  final Completer<void> _gate = Completer<void>();
  bool stopped = false;

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    required int maxTokens,
    required double temperature,
    int seed = 1234,
  }) async* {
    yield const LlmToken('Once upon');
    yield const LlmToken(' a time');
    await _gate.future;
    yield LlmDone(
      GenerationStats(
        prefillMs: 1,
        tokens: 2,
        decodeMs: 1,
        end: stopped ? GenerationEnd.stopped : GenerationEnd.endOfTurn,
      ),
    );
  }

  @override
  void stop() {
    stopped = true;
    if (!_gate.isCompleted) _gate.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakeRuntime runtime;

  setUp(() {
    root = Directory.systemTemp.createTempSync('history_test');
    runtime = FakeRuntime();
  });

  tearDown(() => root.deleteSync(recursive: true));

  ChatStore storeAt() => ChatStore(Directory('${root.path}/chats'));

  ModelManager managerFor(FakeRuntime rt) => ModelManager(
    rootDir: root,
    runtime: rt,
    usableRamBytes: () async => 6 * 1024 * 1024 * 1024,
    threads: 4,
  )..init();

  Future<void> addModel(
    ModelManager m,
    String file,
    ModelProfile profile,
    String name,
  ) async {
    final f = File('${root.path}/models/$file');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(
      Uint8List.fromList([...'GGUF'.codeUnits, ...List.filled(64, 0)]),
    );
    await m.registerFile(fileName: file, displayName: name, profile: profile);
  }

  var settingsFileCount = 0;

  AppController controllerFor(ModelManager m, ChatStore s, [FakeRuntime? rt]) =>
      AppController(
        manager: m,
        runtime: rt ?? runtime,
        importer: ModelImporter(),
        store: s,
        suggestedThreads: 4,
        webSearch: FakeWebSearchService(configured: false),
        searchSettingsStore: SearchSettingsStore(
          File('${root.path}/search_settings_${settingsFileCount++}.json'),
        ),
      );

  group('ChatStore', () {
    test('create, save, and restore a conversation', () {
      final store = storeAt();
      final now = DateTime(2026, 10, 6, 18);
      final c = Conversation(
        id: 'c1',
        modelId: 'm1',
        profileId: chatProfile.id,
        createdAt: now,
        updatedAt: now,
        messages: [
          StoredMessage(isUser: true, text: 'Explain friction', createdAt: now),
          StoredMessage(
            isUser: false,
            text: 'Friction is a force.',
            createdAt: now,
          ),
        ],
      );
      store.save(c);
      final back = storeAt().get('c1')!;
      expect(back.messages.length, 2);
      expect(back.messages.first.isUser, isTrue);
      expect(back.messages.last.text, 'Friction is a force.');
      expect(back.modelId, 'm1');
      expect(back.profileId, chatProfile.id);
      expect(back.createdAt, now);
    });

    test('title comes from the first user message', () {
      final c = Conversation(
        id: 'c',
        modelId: 'm',
        profileId: chatProfile.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [
          StoredMessage(
            isUser: true,
            text: '  Python   login system ',
            createdAt: DateTime.now(),
          ),
        ],
      );
      expect(c.title, 'Python login system');
    });

    test('history is sorted by most recent update', () {
      final store = storeAt();
      final old = DateTime(2026, 10, 1);
      final recent = DateTime(2026, 10, 5);
      store.save(
        Conversation(
          id: 'a',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: old,
          updatedAt: old,
        ),
      );
      store.save(
        Conversation(
          id: 'b',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: recent,
          updatedAt: recent,
        ),
      );
      expect(storeAt().listAll().map((c) => c.id).toList(), ['b', 'a']);
    });

    test('delete one removes only that conversation', () {
      final store = storeAt();
      final now = DateTime.now();
      store.save(
        Conversation(
          id: 'a',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: now,
          updatedAt: now,
        ),
      );
      store.save(
        Conversation(
          id: 'b',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: now,
          updatedAt: now,
        ),
      );
      store.delete('a');
      expect(storeAt().listAll().map((c) => c.id).toList(), ['b']);
    });

    test('delete all removes chats and leaves models alone', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final store = storeAt();
      final now = DateTime.now();
      store.save(
        Conversation(
          id: 'a',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: now,
          updatedAt: now,
        ),
      );
      store.save(
        Conversation(
          id: 'b',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: now,
          updatedAt: now,
        ),
      );
      store.deleteAll();
      expect(storeAt().listAll(), isEmpty);
      expect(File('${root.path}/models/llama.gguf').existsSync(), isTrue);
      expect(managerFor(runtime).models, hasLength(1));
    });

    test('a damaged file is skipped and does not hide other chats', () {
      final store = storeAt();
      final now = DateTime.now();
      store.save(
        Conversation(
          id: 'good',
          modelId: 'm',
          profileId: chatProfile.id,
          createdAt: now,
          updatedAt: now,
        ),
      );
      File('${root.path}/chats/broken.json').writeAsStringSync('{ not json');
      expect(storeAt().listAll().map((c) => c.id).toList(), ['good']);
    });
  });

  group('AppController chat history', () {
    test('sending saves the user message and the assistant reply', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final store = storeAt();
      final c = controllerFor(mgr, store);
      await c.loadModel(mgr.models.single.id);
      await c.send('hi there');

      final saved = store.listAll().single;
      expect(saved.messages.map((m) => m.isUser).toList(), [true, false]);
      expect(saved.messages.first.text, 'hi there');
      expect(saved.messages.last.text, 'hi');
      expect(saved.title, 'hi there');
    });

    test('conversation survives an app restart and can be continued', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final first = controllerFor(mgr, storeAt());
      await first.loadModel(mgr.models.single.id);
      await first.send('first question');

      // A new controller and store, as after a restart.
      final mgr2 = managerFor(runtime);
      final second = controllerFor(mgr2, storeAt());
      final id = second.history.single.id;
      second.openConversation(id);
      expect(second.messages.map((m) => m.text).toList(), [
        'first question',
        'hi',
      ]);
      expect(second.access, ChatAccess.needsLoad);

      await second.loadModel(mgr2.models.single.id);
      expect(second.access, ChatAccess.ready);
      expect(
        second.messages.length,
        2,
        reason: 'loading the chat’s own model keeps the chat',
      );
      await second.send('follow-up');
      expect(storeAt().get(id)!.messages.length, 4);
    });

    test(
      'switching models starts a new chat and keeps the old one in history',
      () async {
        final mgr = managerFor(runtime);
        await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
        await addModel(mgr, 'qwen.gguf', codingProfile, 'Qwen');
        final c = controllerFor(mgr, storeAt());
        final llama = mgr.models
            .firstWhere((m) => m.fileName == 'llama.gguf')
            .id;
        final qwen = mgr.models.firstWhere((m) => m.fileName == 'qwen.gguf').id;

        await c.loadModel(llama);
        await c.send('about llama');
        await c.loadModel(qwen);
        expect(c.messages, isEmpty);
        await c.send('about qwen');

        final titles = c.history.map((h) => h.title).toList();
        expect(titles, containsAll(['about llama', 'about qwen']));
        expect(c.history.length, 2);
      },
    );

    test(
      'a chat whose model was deleted is readable but cannot be continued',
      () async {
        final mgr = managerFor(runtime);
        await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
        final c = controllerFor(mgr, storeAt());
        await c.loadModel(mgr.models.single.id);
        await c.send('keep me');
        final id = c.history.single.id;
        await c.deleteModel(mgr.models.single.id);

        c.openConversation(id);
        expect(c.messages.first.text, 'keep me');
        expect(c.access, ChatAccess.modelMissing);
        expect(c.modelNameFor(c.history.single.modelId), isNull);
        await c.send('hello again');
        expect(c.errorMessage, contains('no longer installed'));
        expect(
          c.messages.length,
          2,
          reason: 'nothing is added while the chat is locked',
        );
      },
    );

    test('opening a chat never loads another model silently', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      await addModel(mgr, 'qwen.gguf', codingProfile, 'Qwen');
      final c = controllerFor(mgr, storeAt());
      final llama = mgr.models.firstWhere((m) => m.fileName == 'llama.gguf').id;
      await c.loadModel(llama);
      await c.send('hello');
      await c.unloadModel();
      final id = c.history.single.id;
      c.openConversation(id);
      expect(c.loadedModel, isNull);
      expect(c.access, ChatAccess.needsLoad);
      await c.send('still here?');
      expect(c.errorMessage, contains('Load'));
    });

    test('new chat keeps old chats in history', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final c = controllerFor(mgr, storeAt());
      await c.loadModel(mgr.models.single.id);
      await c.send('one');
      c.newChat();
      expect(c.messages, isEmpty);
      await c.send('two');
      expect(c.history.map((h) => h.title).toSet(), {'one', 'two'});
    });

    test('deleting one chat keeps the others and the models', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final c = controllerFor(mgr, storeAt());
      await c.loadModel(mgr.models.single.id);
      await c.send('one');
      c.newChat();
      await c.send('two');
      final oneId = c.history.firstWhere((h) => h.title == 'one').id;
      c.deleteConversation(oneId);
      expect(c.history.map((h) => h.title).toList(), ['two']);
      expect(mgr.models, hasLength(1));
    });

    test('deleting all chats keeps the models', () async {
      final mgr = managerFor(runtime);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final c = controllerFor(mgr, storeAt());
      await c.loadModel(mgr.models.single.id);
      await c.send('one');
      c.deleteAllConversations();
      expect(c.history, isEmpty);
      expect(c.messages, isEmpty);
      expect(mgr.models, hasLength(1));
    });

    test('a stopped reply keeps its partial text and is saved', () async {
      final slow = SlowRuntime();
      final mgr = managerFor(slow);
      await addModel(mgr, 'llama.gguf', chatProfile, 'Llama');
      final store = storeAt();
      final c = controllerFor(mgr, store, slow);
      await c.loadModel(mgr.models.single.id);
      final sending = c.send('tell a story');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.stopGeneration();
      await sending;

      expect(c.generating, isFalse);
      expect(c.messages.last.text, 'Once upon a time');
      final saved = store.listAll().single;
      expect(saved.messages.last.text, 'Once upon a time');
    });
  });
}
