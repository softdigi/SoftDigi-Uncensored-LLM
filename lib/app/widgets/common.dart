import 'package:flutter/material.dart';

import '../../models/memory_estimator.dart';
import '../../models/model_profile.dart';
import '../../models/model_registry.dart';
import '../../search/search_mode.dart';

/// Asks whether a model is for chat or for coding. Returns null if dismissed.
Future<ModelProfile?> chooseModelUse(BuildContext context) {
  return showModalBottomSheet<ModelProfile>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What is this model for?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _UseOption(
              icon: Icons.chat_bubble_outline,
              title: 'Chat',
              subtitle: 'General conversation and questions',
              onTap: () => Navigator.pop(context, chatProfile),
            ),
            const SizedBox(height: 8),
            _UseOption(
              icon: Icons.code,
              title: 'Coding',
              subtitle: 'Writing and explaining code',
              onTap: () => Navigator.pop(context, codingProfile),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Asks how much network access Web Search may use. Returns null if dismissed.
Future<SearchMode?> chooseSearchMode(
  BuildContext context,
  SearchMode current,
) {
  return showModalBottomSheet<SearchMode>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Web Search',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Your conversations and AI reasoning stay on your device. '
              'Web Search is used only when you allow it.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _UseOption(
              icon: Icons.lock_outline,
              title: 'Local Only',
              subtitle: 'Never access the network, ever.',
              selected: current == SearchMode.localOnly,
              onTap: () => Navigator.pop(context, SearchMode.localOnly),
            ),
            const SizedBox(height: 8),
            _UseOption(
              icon: Icons.public,
              title: 'Smart (default)',
              subtitle: 'Ask before any web search.',
              selected: current == SearchMode.smart,
              onTap: () => Navigator.pop(context, SearchMode.smart),
            ),
            const SizedBox(height: 8),
            _UseOption(
              icon: Icons.public,
              title: 'Web Search Allowed',
              subtitle: 'Search automatically when it looks useful. Reasoning still stays on this device.',
              selected: current == SearchMode.webSearchAllowed,
              onTap: () => Navigator.pop(context, SearchMode.webSearchAllowed),
            ),
          ],
        ),
      ),
    ),
  );
}

class _UseOption extends StatelessWidget {
  const _UseOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.primary, width: 1.5),
            )
          : null,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: selected
            ? Icon(Icons.check_circle, color: scheme.primary)
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// A dismissible message card for errors, notices and busy states.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.message,
    required this.icon,
    required this.color,
    this.onDismiss,
    this.progress = false,
  });

  final String message;
  final IconData icon;
  final Color color;
  final VoidCallback? onDismiss;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              if (progress)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onSurface, height: 1.3),
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onDismiss,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the metadata of an installed model in a bottom sheet.
Future<void> showModelDetails(BuildContext context, InstalledModel model) {
  final profile = profileById(model.profileId);
  final f = model.facts;
  final contextTokens =
      profile?.defaultContext ?? MemoryPolicy.minContextTokens;
  final estimate = estimateMemory(f, contextTokens);
  final maxCtx = maxContextFor(f);
  final rows = <(String, String)>[
    ('Use', profile?.displayName ?? 'Not set'),
    ('File size', formatMegabytes(model.sizeBytes)),
    ('Architecture', f.arch),
    ('Layers', '${f.nLayer}'),
    ('Attention heads', '${f.nHead} (${f.nHeadKv} key/value)'),
    ('Head size', '${f.headDim}'),
    ('Vocabulary', '${f.nVocab}'),
    ('Trained context', '${f.nCtxTrain} tokens'),
    (
      'Context limit on this phone',
      maxCtx == null ? 'Does not fit' : '$maxCtx tokens',
    ),
    ('Estimated RAM at $contextTokens tokens', formatMegabytes(estimate.total)),
    ('Added', _date(model.importedAt)),
  ];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                model.displayName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          label,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(child: Text(value)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

String formatMegabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

String _date(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// True when the profile is the coding profile.
bool profileIsCoding(String profileId) =>
    profileById(profileId)?.role == ModelRole.coding;

/// Date and time for lists, e.g. "6 Oct 2026, 18:42".
String formatWhen(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}
