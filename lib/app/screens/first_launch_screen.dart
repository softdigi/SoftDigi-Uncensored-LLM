import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../widgets/common.dart';
import 'models_screen.dart';

/// Shown when no model is installed yet.
class FirstLaunchScreen extends StatelessWidget {
  const FirstLaunchScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _import(BuildContext context) async {
    final profile = await chooseModelUse(context);
    if (profile == null) return;
    await controller.importModel(profile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Image.asset(
                        'assets/image/softdigi_ai_logo.png',
                        height: 120,
                        fit: BoxFit.contain,
                        semanticLabel: 'SoftDigi AI logo',
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'SoftDigi AI',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Your AI. Your Device. Your Privacy.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Powered by SoftDigi Technology',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'SoftDigi AI runs AI directly on your device.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 24),
                      const _Point(
                        icon: Icons.file_present_outlined,
                        text:
                            'Import a compatible GGUF model file from your phone to begin.',
                      ),
                      const _Point(
                        icon: Icons.lock_outline,
                        text:
                            'Models are copied into the app’s private storage. '
                            'No model is included with the app.',
                      ),
                      const _Point(
                        icon: Icons.wifi_off_outlined,
                        text:
                            'Your chat history is stored locally on this device and is not uploaded to a server.',
                      ),
                      const SizedBox(height: 28),
                      if (controller.busy)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            children: [
                              const LinearProgressIndicator(),
                              const SizedBox(height: 8),
                              Text(
                                controller.busyMessage ?? 'Please wait…',
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      if (controller.errorMessage != null)
                        Card(
                          color: theme.colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              controller.errorMessage!,
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: controller.busy
                            ? null
                            : () => _import(context),
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('Import GGUF Model'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => Scaffold(
                              appBar: AppBar(
                                title: const Text('Installed models'),
                              ),
                              body: ModelsScreen(controller: controller),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.memory_outlined),
                        label: const Text('Installed Models'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
        ],
      ),
    );
  }
}
