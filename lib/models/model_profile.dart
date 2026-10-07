import '../llm/chat_prompt.dart';

enum ModelRole { chat, coding }

/// Application identity, shared by every profile. The product is SoftDigi AI, developed by
/// SoftDigi Technology. The underlying model is named separately by each profile, so the app
/// is never presented as the model's developer.
const String _appIdentity =
    'You are SoftDigi AI, an on-device AI assistant developed by SoftDigi Technology. '
    'Your application identity is SoftDigi AI. You run locally on the user\'s device using the '
    'currently installed AI model. When asked who developed the application, identify SoftDigi '
    'Technology. When asked about the underlying model, identify the actual currently loaded model '
    'and its developer when known. Never confuse the application developer with the underlying '
    'model developer. Answer in the same language the user writes in.';

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
    required this.modelName,
    required this.modelDeveloper,
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

  /// Name of the underlying model this profile runs, e.g. "Llama 3.2 3B Instruct".
  final String modelName;

  /// Developer of the underlying model, not of the application.
  final String modelDeveloper;

  final String? systemPrompt;

  /// Filename the model is usually distributed under. Shown as a hint only.
  final String? suggestedFileName;
}

/// Chat model. Llama 3.2 3B Instruct, Q4_K_M. This is the verified model.
const ModelProfile chatProfile = ModelProfile(
  id: 'chat-llama32-3b-q4km',
  role: ModelRole.chat,
  displayName: 'Chat model',
  format: PromptFormat.llama3,
  defaultContext: 2048,
  temperature: 0.7,
  maxNewTokens: 512,
  modelName: 'Llama 3.2 3B Instruct',
  modelDeveloper: 'Meta',
  systemPrompt:
      '$_appIdentity The underlying model for this conversation is Llama 3.2 3B Instruct, '
      'developed by Meta. Answer concisely.',
  suggestedFileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
);

/// Coding model. Qwen Coder 1.5B or 3B. Not downloaded automatically.
/// Uses the ChatML template and lower temperature.
const ModelProfile codingProfile = ModelProfile(
  id: 'coding-qwen-coder',
  role: ModelRole.coding,
  displayName: 'Coding model',
  format: PromptFormat.chatml,
  defaultContext: 4096,
  temperature: 0.2,
  maxNewTokens: 768,
  modelName: 'Qwen2.5-Coder 1.5B Instruct',
  modelDeveloper: 'Alibaba Cloud',
  systemPrompt:
      '$_appIdentity The underlying model for this conversation is Qwen2.5-Coder 1.5B Instruct, '
      'developed by Alibaba Cloud. Explain briefly and give correct code.',
  suggestedFileName: 'qwen2.5-coder-1.5b-instruct-q4_k_m.gguf',
);

const List<ModelProfile> allProfiles = [chatProfile, codingProfile];

ModelProfile? profileById(String id) {
  for (final p in allProfiles) {
    if (p.id == id) return p;
  }
  return null;
}
