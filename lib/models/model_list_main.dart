// Manual test entry for model import and selection (not the final app UI).
// Run: flutter run -t lib/models/model_list_main.dart
//
// Flow to test on the phone:
//   Import GGUF -> pick a file -> choose its use (chat or coding) ->
//   validate -> copy to private storage -> metadata shown -> Load.
import 'dart:io';

import 'package:flutter/material.dart';

import '../llm/llm_worker.dart';
import 'device_memory.dart';
import 'model_importer.dart';
import 'model_list_page.dart';
import 'model_manager.dart';
import 'model_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final importer = ModelImporter();
  final filesDir = await importer.privateFilesDir();
  final worker = await LlmWorker.spawn();
  final manager = ModelManager(
    rootDir: Directory(filesDir),
    runtime: WorkerModelRuntime(worker),
    usableRamBytes: readUsableRamBytes,
    threads: 4,
  )..init();

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ModelListPage(manager: manager, importer: importer),
    ),
  );
}
