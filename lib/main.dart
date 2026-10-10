import 'dart:io';

import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'app/soft_local_pai_app.dart';
import 'chat/chat_store.dart';
import 'llm/llm_worker.dart';
import 'models/device_memory.dart';
import 'models/model_importer.dart';
import 'models/model_manager.dart';
import 'models/model_runtime.dart';
import 'search/search_config.dart';
import 'search/search_settings_store.dart';
import 'search/web_search_service.dart';

/// SoftDigi AI. Production entry point.
///
/// Startup: the model storage folder is resolved, the inference worker isolate
/// is started, and the installed models are read. Nothing is loaded into memory
/// until the user chooses a model.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final importer = ModelImporter();
  final filesDir = await importer.privateFilesDir();
  final worker = await LlmWorker.spawn();
  final runtime = WorkerModelRuntime(worker);
  final threads = await worker.suggestThreads();

  final manager = ModelManager(
    rootDir: Directory(filesDir),
    runtime: runtime,
    usableRamBytes: readUsableRamBytes,
    threads: threads,
  )..init();

  final controller = AppController(
    manager: manager,
    runtime: runtime,
    importer: importer,
    store: ChatStore(Directory('$filesDir/chats')),
    suggestedThreads: threads,
    // Self-hosted SearXNG only, no API key, no cloud LLM. Unset by default;
    // see lib/search/search_config.dart for how to set it at build time.
    webSearch: SearxngWebSearchService(endpoint: searxngEndpointFromBuild),
    searchSettingsStore: SearchSettingsStore(
      File('$filesDir/search_settings.json'),
    ),
  );

  runApp(SoftLocalPaiApp(controller: controller));
}
