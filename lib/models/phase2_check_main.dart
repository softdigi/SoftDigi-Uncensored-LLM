// On-device verification of Phase 2 (ModelManager, profiles, memory policy,
// context fitting, thermal, crash recovery, switching). Not the app UI.
// Run: flutter run -t lib/models/phase2_check_main.dart
//
// Expects models in the app's private folder: files/models/llama.gguf (the verified
// Llama 3.2 3B). The switch check uses files/models/second.gguf, a copy of the same
// file registered under the coding profile. It exercises switching mechanics only.
import 'dart:io';

import 'package:flutter/material.dart';

import '../chat/chat_session.dart';
import '../chat/context_manager.dart';
import '../engines/media_engines.dart';
import '../llm/chat_prompt.dart';
import '../llm/llm_engine.dart';
import '../llm/llm_worker.dart';
import 'crash_marker.dart';
import 'device_memory.dart';
import 'memory_estimator.dart';
import 'model_importer.dart';
import 'model_manager.dart';
import 'model_profile.dart';
import 'model_runtime.dart';
import 'thermal_policy.dart';

/// TEST-ONLY. Never true in production code. Leaves the live memory gate
/// in place, but reports unlimited usable memory so a check can run on a
/// crowded phone. Keep false for real measurements.
const bool bypassLiveRamGateForTest = false;

Future<int> checkRamProbe() async =>
    bypassLiveRamGateForTest ? (1 << 40) : readUsableRamBytes();

void main() {
  runApp(const _CheckApp());
}

class _CheckApp extends StatelessWidget {
  const _CheckApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(padding: EdgeInsets.all(12), child: _CheckLog()),
      ),
    );
  }
}

class _CheckLog extends StatefulWidget {
  const _CheckLog();

  @override
  State<_CheckLog> createState() => _CheckLogState();
}

class _CheckLogState extends State<_CheckLog> {
  final List<String> _lines = [];
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String s) {
    debugPrint('[phase2] $s');
    setState(() => _lines.add(s));
  }

  void _check(String name, bool ok, [String detail = '']) {
    if (!ok) _failures++;
    _log('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' - $detail'}');
  }

  Future<String> _reply(ChatSession session, String text) async {
    final buffer = StringBuffer();
    GenerationStats? stats;
    await for (final event in session.send(text)) {
      switch (event) {
        case LlmToken(:final text):
          buffer.write(text);
          setState(() => _lines.add('  … ${text.replaceAll('\n', ' ')}'));
        case LlmDone(stats: final done):
          stats = done;
      }
    }
    _log('stats: ${stats ?? 'n/a'}');
    return buffer.toString();
  }

  Future<void> _run() async {
    final importer = ModelImporter();
    final filesDir = await importer.privateFilesDir();
    final worker = await LlmWorker.spawn();
    final runtime = WorkerModelRuntime(worker);
    final manager = ModelManager(
      rootDir: Directory(filesDir),
      runtime: runtime,
      usableRamBytes: checkRamProbe,
      threads: 4,
    );
    try {
      _log('private files dir: $filesDir');
      _log('rss start: ${processRssMb()} MB');
      manager.init();
      for (final note in manager.recoveryNotes) {
        _log('recovery: $note');
      }

      // 1. Registration and GGUF validation.
      if (manager.models.where((m) => m.profileId == chatProfile.id).isEmpty) {
        await manager.registerFile(
          fileName: 'llama.gguf',
          displayName: 'Llama 3.2 3B (test)',
          profile: chatProfile,
        );
      }
      final chat = manager.models.firstWhere(
        (m) => m.profileId == chatProfile.id,
      );
      _check(
        'model registered with metadata',
        chat.facts.nLayer == 28 && chat.facts.nHeadKv == 8,
        chat.facts.toString(),
      );

      final badHeaderCheck = await _rejectsBadHeader(manager);
      _check('non-GGUF file is rejected and removed', badHeaderCheck);

      // 2. Memory estimate and context limit.
      final maxCtx = maxContextFor(chat.facts)!;
      final e2048 = estimateMemory(chat.facts, 2048);
      _log(
        'estimate @2048: weights ${_mb(e2048.weights)} MB, kv ${_mb(e2048.kvCache)} MB, '
        'compute ${_mb(e2048.compute)} MB, overhead ${_mb(e2048.overhead)} MB, '
        'margin ${_mb(e2048.margin)} MB, total ${_mb(e2048.total)} MB',
      );
      _log(
        'budget ${_mb(MemoryPolicy.budgetBytes)} MB, max context $maxCtx tokens',
      );
      _check(
        'estimate is within budget at default context',
        e2048.total <= MemoryPolicy.budgetBytes,
      );

      // 3. Activation with the chat profile.
      final report = await manager.activate(chat.id, profile: chatProfile);
      _log(
        'activated ${report.model.displayName}: ctx ${report.contextTokens}'
        '${report.contextClamped ? ' (clamped)' : ''}, load ${report.loadMs} ms, '
        'estimate ${_mb(report.estimate.total)} MB, rss ${processRssMb()} MB',
      );
      _check('chat model loaded', manager.active?.profileId == chatProfile.id);

      final session = ChatSession(
        profile: chatProfile,
        runtime: runtime,
        contextTokens: report.contextTokens,
        suggestedThreads: LlmEngine.suggestThreads(),
        thermal: () async =>
            thermalLevelFromCode(await importer.thermalStatusCode()),
        unloadActive: manager.deactivate,
      );

      // 4. Chat turns through the context manager.
      final a1 = await _reply(
        session,
        'What is the capital of France? Answer in one short sentence.',
      );
      _check('chat reply is correct', a1.contains('Paris'), a1.trim());
      final a2 = await _reply(session, 'What language is spoken there?');
      _check(
        'second turn uses history and answers',
        a2.trim().isNotEmpty,
        a2.trim(),
      );
      _check(
        'transcript holds both turns',
        session.transcript.length == 4,
        'messages=${session.transcript.length}',
      );

      // 5. Exact context trimming with the real tokenizer.
      final long = [
        for (var i = 0; i < 40; i++) ...[
          ChatMessage(ChatRole.user, 'Tell me fact $i. ${'detail ' * 40}'),
          ChatMessage(ChatRole.assistant, 'Fact $i was noted. ${'note ' * 40}'),
        ],
      ];
      final fitter = ContextManager(
        format: chatProfile.format,
        contextTokens: report.contextTokens,
        maxNewTokens: chatProfile.maxNewTokens,
        countTokens: runtime.countTokens,
        systemPrompt: chatProfile.systemPrompt,
      );
      final fitted = await fitter.fit(
        long,
        const ChatMessage(ChatRole.user, 'Summarize.'),
      );
      _log(
        'trim: dropped ${fitted.droppedMessages} of ${long.length} messages, '
        '${fitted.promptTokens} prompt tokens',
      );
      _check(
        'long history is trimmed to fit the context',
        fitted.droppedMessages > 0 &&
            fitted.promptTokens + chatProfile.maxNewTokens + 32 <=
                report.contextTokens,
      );

      // 6. Thermal policy on this device.
      final level = thermalLevelFromCode(await importer.thermalStatusCode());
      final decision = decideThermal(
        level,
        suggestedThreads: LlmEngine.suggestThreads(),
        requestedMaxTokens: chatProfile.maxNewTokens,
      );
      _log('thermal level: ${level.name}, decision: ${decision.message}');

      // 7. Crash recovery: a marker left by an interrupted load quarantines the model.
      await manager.deactivate();
      CrashMarker(File('$filesDir/models/loading.marker')).begin(chat.id);
      final restarted = ModelManager(
        rootDir: Directory(filesDir),
        runtime: runtime,
        usableRamBytes: checkRamProbe,
        threads: 4,
      )..init();
      _check(
        'interrupted load quarantines the model',
        restarted.byId(chat.id)!.isQuarantined,
      );
      var refused = false;
      try {
        await restarted.activate(chat.id, profile: chatProfile);
      } on ModelManagerException {
        refused = true;
      }
      _check('quarantined model is refused', refused);
      restarted.clearQuarantine(chat.id);
      _log('quarantine cleared');

      // 8. Switching: the coding profile model replaces the chat model, then switch back.
      final secondFile = File('$filesDir/models/second.gguf');
      if (secondFile.existsSync()) {
        if (restarted.models
            .where((m) => m.fileName == 'second.gguf')
            .isEmpty) {
          await restarted.registerFile(
            fileName: 'second.gguf',
            displayName: 'Second copy (switch test)',
            profile: codingProfile,
          );
        }
        final second = restarted.models.firstWhere(
          (m) => m.fileName == 'second.gguf',
        );
        final switched = await restarted.activate(
          second.id,
          profile: codingProfile,
        );
        _check(
          'switch loads the second model',
          restarted.active?.id == second.id,
          'ctx ${switched.contextTokens}, load ${switched.loadMs} ms',
        );
        final back = await restarted.activate(chat.id, profile: chatProfile);
        _check(
          'switch back to the chat model',
          restarted.active?.id == chat.id,
          'ctx ${back.contextTokens}, load ${back.loadMs} ms',
        );
      } else {
        _log('switch check skipped: files/models/second.gguf not present');
      }

      // 9. Reload after unload: the chat model answers again.
      await restarted.deactivate();
      _check('unload frees the model', restarted.active == null);
      _log('rss after unload: ${processRssMb()} MB');
      await restarted.activate(chat.id, profile: chatProfile);
      final s2 = ChatSession(
        profile: chatProfile,
        runtime: runtime,
        contextTokens: report.contextTokens,
        suggestedThreads: LlmEngine.suggestThreads(),
        thermal: () async => ThermalLevel.none,
        unloadActive: restarted.deactivate,
      );
      final reloaded = await _reply(
        s2,
        'Name one primary color. Answer in one word.',
      );
      _check(
        'reload produces a reply',
        reloaded.trim().isNotEmpty,
        reloaded.trim(),
      );

      // 10. Media engines are placeholders.
      _log(
        'image engine: ${const ComingSoonImageEngine().status}; '
        'video engine: ${const ComingSoonVideoEngine().status}',
      );
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

  Future<bool> _rejectsBadHeader(ModelManager manager) async {
    final bad = File('${manager.modelsDir.path}/bad-header.gguf');
    bad.writeAsBytesSync([0x5A, 0x49, 0x50, 0x21, 0, 0, 0, 0]);
    try {
      await manager.registerFile(
        fileName: 'bad-header.gguf',
        displayName: 'bad',
        profile: chatProfile,
      );
      return false;
    } on ModelManagerException {
      return !bad.existsSync();
    }
  }

  static String _mb(int bytes) => (bytes / mib).toStringAsFixed(0);

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
