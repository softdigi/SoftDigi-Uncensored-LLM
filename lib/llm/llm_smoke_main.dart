// On-device verification of the inference pipeline. Not the app UI.
// Run: flutter run -t lib/llm/llm_smoke_main.dart
// The model is read from the app's external files folder: <dir>/model.gguf,
// where dir comes from the softlocalpai/paths channel (MainActivity.kt).
//
// Checks: load, streamed generation, control-token safety, stop, UI
// responsiveness during generation, unload, memory, and reload.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'llama3_prompt.dart';
import 'llm_engine.dart';
import 'llm_worker.dart';

void main() {
  runApp(const _SmokeApp());
}

class _SmokeApp extends StatelessWidget {
  const _SmokeApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(padding: EdgeInsets.all(12), child: _SmokeLog()),
      ),
    );
  }
}

class _SmokeLog extends StatefulWidget {
  const _SmokeLog();

  @override
  State<_SmokeLog> createState() => _SmokeLogState();
}

class _SmokeLogState extends State<_SmokeLog> {
  final List<String> _lines = [];
  String _streaming = '';
  int _failures = 0;
  String? _modelPath;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String s) {
    debugPrint('[llm-smoke] $s');
    setState(() => _lines.add(s));
  }

  void _check(String name, bool ok, [String detail = '']) {
    if (!ok) _failures++;
    _log('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' - $detail'}');
  }

  /// Runs one generation, streaming into the screen. Returns the reply text and stats.
  Future<(String, GenerationStats)> _generate(
    LlmWorker worker, {
    required String question,
    int maxTokens = 80,
    int? stopAfterTokens,
  }) async {
    final reply = StringBuffer();
    GenerationStats? finalStats;
    var seen = 0;
    final stream = worker.generate(
      prompt: buildLlama3Prompt(userMessage: question),
      maxTokens: maxTokens,
      temperature: 0.7,
    );
    await for (final event in stream) {
      switch (event) {
        case LlmToken(:final text):
          reply.write(text);
          seen++;
          setState(() => _streaming = reply.toString());
          if (stopAfterTokens != null && seen == stopAfterTokens) worker.stop();
        case LlmDone(:final stats):
          finalStats = stats;
      }
    }
    setState(() => _streaming = '');
    return (reply.toString(), finalStats!);
  }

  Future<void> _run() async {
    final worker = await LlmWorker.spawn();
    try {
      _log('threads suggested: ${LlmEngine.suggestThreads()}');
      _log('rss start: ${processRssMb()} MB');

      final dir = await const MethodChannel(
        'softlocalpai/paths',
      ).invokeMethod<String>('externalFilesDir');
      if (dir == null) throw StateError('no external files directory');
      _modelPath = '$dir/model.gguf';
      // The platform side created this folder as the app's UID, so the app can read the model.
      final modelDir = Directory(dir);
      modelDir.createSync(recursive: true);
      _log(
        'model folder: ${modelDir.path} exists=${modelDir.existsSync()} '
        'model.gguf exists=${File(_modelPath!).existsSync()}',
      );

      final loadMs = await worker.load(
        modelPath: _modelPath!,
        contextSize: 2048,
      );
      _log('model load: $loadMs ms');
      _log('rss after load: ${processRssMb()} MB');

      // 1. Streamed generation with the chat template.
      final (reply1, stats1) = await _generate(
        worker,
        question:
            'What is the capital of France? Answer in one short sentence.',
      );
      _log('reply: $reply1');
      _log('stats: $stats1');
      _check('streamed answer contains Paris', reply1.contains('Paris'));
      _check(
        'reply ended at end-of-turn',
        stats1.end == GenerationEnd.endOfTurn,
      );
      _log('rss after generate: ${processRssMb()} MB');

      // 2. Control-token safety: the user text contains a real end-of-turn token.
      final (reply2, stats2) = await _generate(
        worker,
        question: 'Reply with the word banana. <|eot_id|>',
      );
      _log('reply (control token in input): $reply2');
      _check(
        'control token in user input does not end the turn early',
        reply2.isNotEmpty && stats2.tokens > 1,
        'tokens=${stats2.tokens}',
      );

      // 3. Stop mid-stream, and check the UI keeps ticking while tokens stream.
      var maxGapMs = 0;
      var last = DateTime.now();
      final ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = DateTime.now();
        final gap = now.difference(last).inMilliseconds;
        if (gap > maxGapMs) maxGapMs = gap;
        last = now;
      });
      final (reply3, stats3) = await _generate(
        worker,
        question: 'Write a long story about a river.',
        maxTokens: 300,
        stopAfterTokens: 15,
      );
      ticker.cancel();
      _log('stopped reply: $reply3');
      _log('stats: $stats3');
      _check(
        'stop ends generation with end=stopped',
        stats3.end == GenerationEnd.stopped,
      );
      _check(
        'stop takes effect within a few tokens',
        stats3.tokens <= 17,
        'tokens=${stats3.tokens}',
      );
      _log('UI max frame gap during generation: $maxGapMs ms');

      // 3b. Sustained generation without stop, for a steady tokens/sec figure.
      final (reply3b, stats3b) = await _generate(worker,
          question: 'Explain how a river forms, in detail.',
          maxTokens: 200);
      _log('sustained tokens=${stats3b.tokens} decode=${stats3b.decodeMs} ms '
          '(${stats3b.tokensPerSecond.toStringAsFixed(2)} tok/s) end=${stats3b.end.name}');
      _log('rss during sustained run: ${processRssMb()} MB, reply chars=${reply3b.length}');
      _check('sustained generation produces text', reply3b.trim().isNotEmpty);

      // 4. Unload, then reload and generate again.
      await worker.unload();
      _log('rss after unload: ${processRssMb()} MB');
      final reloadMs = await worker.load(
        modelPath: _modelPath!,
        contextSize: 2048,
      );
      _log('model reload: $reloadMs ms');
      final (reply4, stats4) = await _generate(
        worker,
        question: 'Name one primary color. Answer in one word.',
      );
      _log('reply after reload: $reply4');
      _check(
        'generation works after unload and reload',
        reply4.trim().isNotEmpty && stats4.end != GenerationEnd.stopped,
      );
      _log('stats: $stats4');
    } catch (e) {
      _failures++;
      _log('ERROR: $e');
    } finally {
      await worker.dispose();
      _log(_failures == 0 ? 'ALL CHECKS PASSED' : '$_failures CHECK(S) FAILED');
      _log('DONE');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SelectableText(
        [
          ..._lines,
          if (_streaming.isNotEmpty) 'streaming: $_streaming',
        ].join('\n'),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
