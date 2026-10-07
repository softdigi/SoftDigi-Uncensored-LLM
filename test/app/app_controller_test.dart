import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/chat/chat_store.dart';
import 'package:soft_local_pai/app/app_controller.dart';
import 'package:soft_local_pai/models/model_importer.dart';
import 'package:soft_local_pai/models/model_manager.dart';
import 'package:soft_local_pai/models/model_profile.dart';

import '../models/fake_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeRuntime runtime;
  late ModelManager manager;
  late AppController controller;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('controller_test');
    runtime = FakeRuntime();
    manager = ModelManager(
      rootDir: root,
      runtime: runtime,
      usableRamBytes: () async => 6 * 1024 * 1024 * 1024,
      threads: 4,
    )..init();
    final file = File('${root.path}/models/llama.gguf');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      Uint8List.fromList([...'GGUF'.codeUnits, ...List.filled(64, 0)]),
    );
    await manager.registerFile(
      fileName: 'llama.gguf',
      displayName: 'Llama 3.2 3B',
      profile: chatProfile,
    );
    controller = AppController(
      manager: manager,
      runtime: runtime,
      importer: ModelImporter(),
      store: ChatStore(Directory('${root.path}/chats')),
      suggestedThreads: 4,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'sending without a loaded model shows a clear error and adds no bubbles',
    () async {
      await controller.send('hello');
      expect(controller.errorMessage, 'Load a model to start chatting.');
      expect(controller.messages, isEmpty);
    },
  );

  test('load, then a reply streams into the assistant bubble', () async {
    await controller.loadModel(_idOf(manager));
    expect(controller.loadedModel, isNotNull);
    expect(controller.canChat, isTrue);

    await controller.send('hi');

    expect(controller.messages.length, 2);
    expect(controller.messages.first.isUser, isTrue);
    expect(controller.messages.last.text, 'hi');
    expect(controller.messages.last.streaming, isFalse);
    expect(controller.generating, isFalse);
  });

  test('a blank message is ignored', () async {
    await controller.loadModel(_idOf(manager));
    await controller.send('   ');
    expect(controller.messages, isEmpty);
  });

  test('switching models starts a new conversation', () async {
    await controller.loadModel(_idOf(manager));
    await controller.send('hi');
    expect(controller.messages, isNotEmpty);

    await controller.loadModel(_idOf(manager));
    expect(
      controller.messages,
      isNotEmpty,
      reason: 'same model keeps its chat',
    );

    controller.newChat();
    expect(controller.messages, isEmpty);
  });

  test('unload clears the loaded model and blocks sending', () async {
    await controller.loadModel(_idOf(manager));
    await controller.unloadModel();
    expect(controller.loadedModel, isNull);
    await controller.send('again');
    expect(controller.errorMessage, 'Load a model to start chatting.');
  });

  test(
    'a refused load (memory gate) shows the reason and keeps no model loaded',
    () async {
      manager = ModelManager(
        rootDir: root,
        runtime: runtime,
        usableRamBytes: () async => 1024 * 1024,
        threads: 4,
      )..init();
      controller = AppController(
        manager: manager,
        runtime: runtime,
        importer: ModelImporter(),
        store: ChatStore(Directory('${root.path}/chats')),
        suggestedThreads: 4,
      );
      await controller.loadModel(_idOf(manager));
      expect(controller.loadedModel, isNull);
      expect(controller.errorMessage, contains('not enough free memory'));
    },
  );

  test('dismissing the error clears it', () async {
    await controller.send('hello');
    controller.dismissError();
    expect(controller.errorMessage, isNull);
  });

  test('changing the use of a model updates its profile', () async {
    controller.setUse(_idOf(manager), codingProfile);
    expect(manager.models.single.profileId, codingProfile.id);
  });
}

String _idOf(ModelManager m) => m.models.single.id;
