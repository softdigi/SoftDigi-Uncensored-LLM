// On-device verification of the coding profile and model switching
// (Llama Chat -> Qwen Coder -> Llama Chat). Not the app UI.
// Run: flutter run -t lib/models/coding_check_main.dart
//
// Expects, in the app's private folder:
//   files/models/llama.gguf       Llama 3.2 3B Instruct Q4_K_M (chat)
//   files/models/coding-qwen.gguf Qwen2.5-Coder 1.5B Instruct Q4_K_M (coding)
import 'dart:io';

import 'package:flutter/material.dart';

import '../chat/chat_session.dart';
import '../llm/chat_prompt.dart';
import '../llm/llm_engine.dart';
import '../llm/llm_worker.dart';
import 'device_memory.dart';
import 'memory_estimator.dart';
import 'model_importer.dart';
import 'model_manager.dart';
import 'model_profile.dart';
import 'model_registry.dart';
import 'model_runtime.dart';
import 'thermal_policy.dart';

void main() {
  runApp(const _CodingApp());
}

class _CodingApp extends StatelessWidget {
  const _CodingApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(padding: EdgeInsets.all(12), child: _CodingLog()),
      ),
    );
  }
}

class _CodingLog extends StatefulWidget {
  const _CodingLog();

  @override
  State<_CodingLog> createState() => _CodingLogState();
}

class _CodingLogState extends State<_CodingLog> {
  final List<String> _lines = [];
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String s) {
    debugPrint('[coding] $s');
    setState(() => _lines.add(s));
  }

  void _check(String name, bool ok, [String detail = '']) {
    if (!ok) _failures++;
    _log('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' - $detail'}');
  }

  Future<(String, GenerationStats?)> _reply(
    ChatSession session,
    String text,
  ) async {
    final buffer = StringBuffer();
    GenerationStats? stats;
    await for (final event in session.send(text)) {
      switch (event) {
        case LlmToken(:final text):
          buffer.write(text);
        case LlmDone(stats: final done):
          stats = done;
      }
    }
    return (buffer.toString(), stats);
  }

  ChatSession _session(
    ModelProfile profile,
    ModelRuntime runtime,
    int contextTokens,
    ModelImporter importer,
    ModelManager manager,
  ) {
    return ChatSession(
      profile: profile,
      runtime: runtime,
      contextTokens: contextTokens,
      suggestedThreads: LlmEngine.suggestThreads(),
      thermal: () async =>
          thermalLevelFromCode(await importer.thermalStatusCode()),
      unloadActive: manager.deactivate,
    );
  }

  Future<void> _run() async {
    final importer = ModelImporter();
    final filesDir = await importer.privateFilesDir();
    final worker = await LlmWorker.spawn();
    final runtime = WorkerModelRuntime(worker);
    final manager = ModelManager(
      rootDir: Directory(filesDir),
      runtime: runtime,
      usableRamBytes: readUsableRamBytes,
      threads: 4,
    );
    try {
      manager.init();
      _log(
        'rss start: ${processRssMb()} MB, usable RAM now: '
        '${(await readUsableRamBytes()) ~/ mib} MB',
      );

      // Registration and metadata.
      final chatModel =
          _find(manager, 'llama.gguf', chatProfile.id) ??
          await manager.registerFile(
            fileName: 'llama.gguf',
            displayName: 'Llama 3.2 3B Instruct (chat)',
            profile: chatProfile,
          );
      final codingModel =
          _find(manager, 'coding-qwen.gguf', codingProfile.id) ??
          await manager.registerFile(
            fileName: 'coding-qwen.gguf',
            displayName: 'Qwen2.5-Coder 1.5B Instruct (coding)',
            profile: codingProfile,
          );
      final f = codingModel.facts;
      _log(
        'coding model: ${f.arch}, ${f.nLayer} layers, ${f.nHeadKv} KV heads, '
        'head dim ${f.headDim}, train ctx ${f.nCtxTrain}, vocab ${f.nVocab}, '
        'file ${codingModel.sizeBytes ~/ mib} MB',
      );
      _check(
        'coding metadata is Qwen2 with the expected sizes',
        f.arch == 'qwen2' &&
            f.nLayer > 0 &&
            f.nHeadKv > 0 &&
            f.headDim > 0 &&
            f.nVocab > 0,
      );
      _check(
        'coding profile uses ChatML',
        codingProfile.format == PromptFormat.chatml,
      );
      final codingMax = maxContextFor(f)!;
      _log(
        'coding max context: $codingMax tokens (default ${codingProfile.defaultContext})',
      );
      _log('chat max context: ${maxContextFor(chatModel.facts)} tokens');

      // Step 1: Llama Chat.
      final r1 = await manager.activate(chatModel.id, profile: chatProfile);
      _log(
        '[1] load Llama chat: ${r1.loadMs} ms, ctx ${r1.contextTokens}, '
        'est ${r1.estimate.total ~/ mib} MB, rss ${processRssMb()} MB',
      );
      final chat1 = _session(
        chatProfile,
        runtime,
        r1.contextTokens,
        importer,
        manager,
      );
      final (a1, s1) = await _reply(
        chat1,
        'What is the capital of France? Answer in one short sentence.',
      );
      _log('[1] reply: ${a1.trim()}');
      _log('[1] ${s1 ?? 'no stats'}');
      _check('[1] Llama chat answers Paris', a1.contains('Paris'));

      // Step 2: switch to Qwen Coder.
      final r2 = await manager.activate(codingModel.id, profile: codingProfile);
      _check(
        '[2] switched to coding model',
        manager.active?.id == codingModel.id,
      );
      _log(
        '[2] load Qwen coder: ${r2.loadMs} ms, ctx ${r2.contextTokens}'
        '${r2.contextClamped ? ' (clamped)' : ''}, est ${r2.estimate.total ~/ mib} MB, '
        'rss ${processRssMb()} MB',
      );
      final coding = _session(
        codingProfile,
        runtime,
        r2.contextTokens,
        importer,
        manager,
      );
      final (a2, s2) = await _reply(
        coding,
        'Write a Python function fib(n) that returns the nth Fibonacci number. Reply with the code only.',
      );
      _log('[2] reply: ${a2.trim()}');
      _log('[2] ${s2 ?? 'no stats'}');
      _check(
        '[2] coding reply contains a Python function',
        a2.contains('def ') && a2.contains('return'),
      );
      _check(
        '[2] reply has no leaked template tokens',
        !a2.contains('<|im_') && !a2.contains('<|endoftext|>'),
      );

      // Step 3: back to Llama Chat.
      final r3 = await manager.activate(chatModel.id, profile: chatProfile);
      _check(
        '[3] switched back to chat model',
        manager.active?.id == chatModel.id,
      );
      _log(
        '[3] load Llama chat again: ${r3.loadMs} ms, rss ${processRssMb()} MB',
      );
      final chat3 = _session(
        chatProfile,
        runtime,
        r3.contextTokens,
        importer,
        manager,
      );
      final (a3, s3) = await _reply(
        chat3,
        'What is the capital of Italy? Answer in one short sentence.',
      );
      _log('[3] reply: ${a3.trim()}');
      _log('[3] ${s3 ?? 'no stats'}');
      _check(
        '[3] Llama chat answers Rome after switching back',
        a3.contains('Rome'),
      );

      // Unload.
      await manager.deactivate();
      _check('unload leaves no model active', manager.active == null);
      _log('rss after unload: ${processRssMb()} MB');
    } catch (e) {
      _failures++;
      _log('ERROR: $e');
    } finally {
      await manager.deactivate();
      await worker.dispose();
      _log(_failures == 0 ? 'ALL CHECKS PASSED' : '$_failures CHECK(S) FAILED');
      _log('DONE');
    }
  }

  InstalledModel? _find(
    ModelManager manager,
    String fileName,
    String profileId,
  ) {
    for (final m in manager.models) {
      if (m.fileName == fileName && m.profileId == profileId) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SelectableText(
        _lines.join('\n'),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
