import 'package:flutter_test/flutter_test.dart';
import 'package:soft_local_pai/chat/context_manager.dart';
import 'package:soft_local_pai/llm/chat_prompt.dart';
import 'package:soft_local_pai/models/model_profile.dart';

/// The six identity questions from the product spec.
const List<String> identityQuestions = [
  'Who are you?',
  'Who created you?',
  'Who developed this app?',
  'Which company developed SoftDigi AI?',
  'Which model are you using?',
  'Who developed the underlying model?',
];

/// Builds the prompt the engine would receive for [question] under [profile].
Future<String> promptFor(ModelProfile profile, String question) async {
  final fitter = ContextManager(
    format: profile.format,
    contextTokens: 8192,
    maxNewTokens: profile.maxNewTokens,
    countTokens: (text) async => text.length ~/ 4,
    systemPrompt: profile.systemPrompt,
  );
  final fitted = await fitter.fit(
    const [],
    ChatMessage(ChatRole.user, question),
  );
  return fitted.prompt;
}

void main() {
  group('application identity in system prompts', () {
    for (final profile in allProfiles) {
      test('${profile.displayName}: names SoftDigi AI and its developer', () {
        final system = profile.systemPrompt!;
        expect(system, contains('You are SoftDigi AI'));
        expect(system, contains('developed by SoftDigi Technology'));
        expect(system, contains('Your application identity is SoftDigi AI'));
        expect(
          system,
          contains(
            'Never confuse the application developer with the underlying model developer',
          ),
        );
      });

      test(
        '${profile.displayName}: names its own underlying model and that model\'s developer',
        () {
          final system = profile.systemPrompt!;
          expect(
            system,
            contains(
              'underlying model for this conversation is ${profile.modelName}',
            ),
          );
          expect(system, contains('developed by ${profile.modelDeveloper}'));
        },
      );
    }

    test(
      'chat profile is Llama, developed by Meta, and never SoftDigi Technology',
      () {
        expect(chatProfile.modelName, 'Llama 3.2 3B Instruct');
        expect(chatProfile.modelDeveloper, 'Meta');
        expect(chatProfile.systemPrompt, isNot(contains('Qwen')));
        expect(chatProfile.systemPrompt, isNot(contains('Alibaba')));
      },
    );

    test(
      'coding profile is Qwen, developed by Alibaba Cloud, and never Llama or Meta',
      () {
        expect(codingProfile.modelName, 'Qwen2.5-Coder 1.5B Instruct');
        expect(codingProfile.modelDeveloper, 'Alibaba Cloud');
        expect(codingProfile.systemPrompt, isNot(contains('Llama')));
        expect(codingProfile.systemPrompt, isNot(contains('Meta')));
      },
    );

    test(
      'no profile says SoftDigi Technology made or trained the underlying model',
      () {
        for (final profile in allProfiles) {
          final system = profile.systemPrompt!;
          expect(system, isNot(contains('SoftDigi Technology created')));
          expect(system, isNot(contains('SoftDigi Technology trained')));
          expect(
            system,
            isNot(contains('SoftDigi Technology developed Llama')),
          );
          expect(system, isNot(contains('Meta created SoftDigi AI')));
        }
      },
    );

    test('existing model-specific instructions are kept', () {
      expect(chatProfile.systemPrompt, contains('Answer concisely.'));
      expect(
        codingProfile.systemPrompt,
        contains('Explain briefly and give correct code.'),
      );
    });
  });

  group(
    'the six identity questions reach the model with the right identity',
    () {
      for (final question in identityQuestions) {
        test('chat: "$question"', () async {
          final prompt = await promptFor(chatProfile, question);
          expect(
            prompt,
            startsWith('<|start_header_id|>system<|end_header_id|>'),
          );
          expect(prompt, contains('You are SoftDigi AI'));
          expect(
            prompt,
            contains('<|start_header_id|>user<|end_header_id|>\n\n$question'),
          );
          expect(
            prompt,
            endsWith('<|start_header_id|>assistant<|end_header_id|>\n\n'),
          );
          expect(prompt, contains('Llama 3.2 3B Instruct'));
        });

        test('coding: "$question"', () async {
          final prompt = await promptFor(codingProfile, question);
          expect(prompt, startsWith('<|im_start|>system\n'));
          expect(prompt, contains('You are SoftDigi AI'));
          expect(prompt, contains('<|im_start|>user\n$question<|im_end|>'));
          expect(prompt, endsWith('<|im_start|>assistant\n'));
          expect(prompt, contains('Qwen2.5-Coder 1.5B Instruct'));
          expect(prompt, isNot(contains('Llama')));
        });
      }

      test(
        'the application developer is never the model developer in any prompt',
        () async {
          for (final profile in allProfiles) {
            for (final q in identityQuestions) {
              final prompt = await promptFor(profile, q);
              expect(prompt, isNot(contains('SoftDigi Technology trained')));
              expect(prompt, isNot(contains('SoftDigi Technology created')));
            }
          }
        },
      );
    },
  );
}
