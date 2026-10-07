import '../llm/chat_prompt.dart';
import '../llm/llm_worker.dart';
import '../models/model_profile.dart';
import '../models/model_runtime.dart';
import '../models/thermal_policy.dart';
import 'context_manager.dart';

/// One conversation with the active model. Keeps the full transcript; the
/// prompt uses only what fits in the context window (see ContextManager).
class ChatSession {
  ChatSession({
    required this.profile,
    required this.runtime,
    required this.contextTokens,
    required this.suggestedThreads,
    required this.thermal,
    required this.unloadActive,
  });

  final ModelProfile profile;
  final ModelRuntime runtime;
  final int contextTokens;
  final int suggestedThreads;

  /// Reads the current thermal level from the device.
  final Future<ThermalLevel> Function() thermal;

  /// Unloads the active model. Called when the thermal policy says the device is overheating.
  final Future<void> Function() unloadActive;

  final List<ChatMessage> transcript = [];

  /// Older messages left out of the last prompt to fit the context window.
  int lastDroppedMessages = 0;

  /// Sends [text] and streams the reply. Applies the thermal policy first.
  /// The reply is appended to [transcript] when it finishes.
  Stream<LlmEvent> send(String text) async* {
    final level = await thermal();
    final decision = decideThermal(
      level,
      suggestedThreads: suggestedThreads,
      requestedMaxTokens: profile.maxNewTokens,
    );
    if (decision.unloadModel) await unloadActive();
    if (!decision.allowGeneration) {
      throw StateError(decision.message);
    }
    final maxTokens = decision.maxNewTokensCap ?? profile.maxNewTokens;

    await runtime.setThreads(decision.threads);
    final fitter = ContextManager(
      format: profile.format,
      contextTokens: contextTokens,
      maxNewTokens: maxTokens,
      countTokens: runtime.countTokens,
      systemPrompt: profile.systemPrompt,
    );
    final userMessage = ChatMessage(ChatRole.user, text);
    final fitted = await fitter.fit(transcript, userMessage);
    lastDroppedMessages = fitted.droppedMessages;

    transcript.add(userMessage);
    final reply = StringBuffer();
    await for (final event in runtime.generate(
      prompt: fitted.prompt,
      maxTokens: maxTokens,
      temperature: profile.temperature,
    )) {
      if (event is LlmToken) reply.write(event.text);
      yield event;
    }
    transcript.add(ChatMessage(ChatRole.assistant, reply.toString()));
  }
}
