import 'package:flutter/material.dart';

import '../../models/memory_estimator.dart';
import '../../models/model_profile.dart';
import '../../models/model_registry.dart';
import '../app_controller.dart';
import '../widgets/common.dart';
import 'model_download_screen.dart';

/// Installed models: import, load, unload, switch, change use, details and delete.
class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _import(BuildContext context) async {
    final profile = await chooseModelUse(context);
    if (profile == null) return;
    await controller.importModel(profile);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    InstalledModel model,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this model?'),
        content: Text(
          '${model.displayName} will be removed from this phone. '
          'You can import it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.deleteModel(model.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final models = controller.models;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Models'),
            actions: [
              IconButton(
                tooltip: 'Download AI Models',
                icon: const Icon(Icons.storefront_outlined),
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ModelDownloadScreen(
                        manager: controller.manager,
                        importer: controller.importer,
                      ),
                    ),
                  );
                  controller.refreshModels();
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: controller.busy ? null : () => _import(context),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import GGUF'),
          ),
          body: Column(
            children: [
              if (controller.busy)
                StatusBanner(
                  message: controller.busyMessage ?? 'Please wait…',
                  icon: Icons.hourglass_top,
                  color: Theme.of(context).colorScheme.primary,
                  progress: true,
                ),
              if (controller.errorMessage != null)
                StatusBanner(
                  message: controller.errorMessage!,
                  icon: Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                  onDismiss: controller.dismissError,
                ),
              if (controller.notice != null)
                StatusBanner(
                  message: controller.notice!,
                  icon: Icons.info_outline,
                  color: Theme.of(context).colorScheme.tertiary,
                  onDismiss: controller.dismissNotice,
                ),
              Expanded(
                child: models.isEmpty
                    ? const _EmptyModels()
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                        itemCount: models.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, i) => _ModelCard(
                          model: models[i],
                          controller: controller,
                          onDelete: () => _confirmDelete(context, models[i]),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyModels extends StatelessWidget {
  const _EmptyModels();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.memory_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('No models yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Import a compatible GGUF model file to start chatting on this phone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.controller,
    required this.onDelete,
  });

  final InstalledModel model;
  final AppController controller;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = profileById(model.profileId);
    final isLoaded = controller.loadedModel?.id == model.id;
    final busy = controller.busy || controller.generating;
    final maxCtx = maxContextFor(model.facts);
    final estimate = estimateMemory(
      model.facts,
      profile?.defaultContext ?? MemoryPolicy.minContextTokens,
    );

    final String status;
    final Color statusColor;
    if (model.isQuarantined) {
      status = 'Needs attention';
      statusColor = scheme.error;
    } else if (isLoaded) {
      status = 'Loaded';
      statusColor = scheme.primary;
    } else {
      status = 'Ready to load';
      statusColor = scheme.onSurfaceVariant;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    model.displayName,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    status,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${profile?.role == ModelRole.coding ? 'Coding' : 'Chat'} · '
              '${formatMegabytes(model.sizeBytes)} · ${model.facts.arch}',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              maxCtx == null
                  ? 'Too large for this phone’s memory budget'
                  : 'Up to $maxCtx tokens of context · about '
                        '${formatMegabytes(estimate.total)} RAM',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (model.isQuarantined) ...[
              const SizedBox(height: 8),
              Text(
                'The last load did not finish (${model.quarantineReason}). '
                'You can try again.',
                style: TextStyle(color: scheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (model.isQuarantined)
                  FilledButton.tonal(
                    onPressed: busy
                        ? null
                        : () => controller.clearQuarantine(model.id),
                    child: const Text('Try again'),
                  )
                else if (isLoaded)
                  FilledButton.tonal(
                    onPressed: busy ? null : controller.unloadModel,
                    child: const Text('Unload'),
                  )
                else
                  FilledButton(
                    onPressed: busy || maxCtx == null
                        ? null
                        : () => controller.loadModel(model.id),
                    child: Text(
                      controller.loadedModel == null
                          ? 'Load'
                          : 'Switch to this',
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  enabled: !busy,
                  onSelected: (value) async {
                    if (value == 'details') {
                      await showModelDetails(context, model);
                    } else if (value == 'chat') {
                      controller.setUse(model.id, chatProfile);
                    } else if (value == 'coding') {
                      controller.setUse(model.id, codingProfile);
                    } else if (value == 'delete') {
                      onDelete();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'details',
                      child: Text('Details'),
                    ),
                    if (profile?.role != ModelRole.chat)
                      const PopupMenuItem(
                        value: 'chat',
                        child: Text('Use for chat'),
                      ),
                    if (profile?.role != ModelRole.coding)
                      const PopupMenuItem(
                        value: 'coding',
                        child: Text('Use for coding'),
                      ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Icon(Icons.more_horiz),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
