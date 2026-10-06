import '../llm/chat_prompt.dart';

enum ModelRole { chat, coding }

/// What a model is for and how to drive it. A profile does not contain a file;
/// the user imports a GGUF and assigns it to a profile.
class ModelProfile {
  const ModelProfile({
    required this.id,
    required this.role,
    required this.displayName,
    required this.format,
    required this.defaultContext,
    required this.temperature,
    required this.maxNewTokens,
    this.systemPrompt,
    this.suggestedFileName,
  });

  final String id;
  final ModelRole role;
  final String displayName;
  final PromptFormat format;
  final int defaultContext;
  final double temperature;
  final int maxNewTokens;
  final String? systemPrompt;

  /// Filename the model is usually distributed under. Shown as a hint only.
  final String? suggestedFileName;
}

/// Chat model. Llama 3.2 3B Instruct, Q4_K_M. This is the verified model.
const ModelProfile chatProfile = ModelProfile(
  id: 'chat-llama32-3b-q4km',
  role: ModelRole.chat,
  displayName: 'Chat: Llama 3.2 3B Instruct (Q4_K_M)',
  format: PromptFormat.llama3,
  defaultContext: 2048,
  temperature: 0.7,
  maxNewTokens: 512,
  systemPrompt: 'You are a helpful assistant. Answer concisely.',
  suggestedFileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
);

/// Coding model. Qwen Coder 1.5B or 3B. Not downloaded automatically.
/// Uses the ChatML template and lower temperature.
const ModelProfile codingProfile = ModelProfile(
  id: 'coding-qwen-coder',
  role: ModelRole.coding,
  displayName: 'Coding: Qwen Coder 1.5B/3B (not installed)',
  format: PromptFormat.chatml,
  defaultContext: 4096,
  temperature: 0.2,
  maxNewTokens: 768,
  systemPrompt:
      'You are a careful programming assistant. Explain briefly and give correct code.',
);

const List<ModelProfile> allProfiles = [chatProfile, codingProfile];

ModelProfile? profileById(String id) {
  for (final p in allProfiles) {
    if (p.id == id) return p;
  }
  return null;
}
