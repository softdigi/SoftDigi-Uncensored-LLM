import 'dart:async';

import 'package:flutter/material.dart';

import '../../download/download_manager.dart';
import '../../download/model_catalog.dart';
import '../../models/memory_estimator.dart';
import '../../models/model_importer.dart';
import '../../models/model_manager.dart';
import '../widgets/common.dart';

enum _Phase { idle, resolving, downloading, verifying, done, paused, failed }

class _EntryUi {
  _Phase phase = _Phase.idle;
  int receivedBytes = 0;
  int totalBytes = 0;
  String? error;
  DownloadHandle? handle;
  StreamSubscription<DownloadProgress>? subscription;
}

/// SoftDigi AI Model Store: browse, inspect and download GGUF models.
///
/// Downloading only ever writes a validated file into private storage and
/// registers it through [ModelManager.registerFile] — the same path SAF
/// Import GGUF already uses. A downloaded model is never loaded here; the
/// user loads it from the Models tab like any other installed model.
class ModelDownloadScreen extends StatefulWidget {
  const ModelDownloadScreen({
    super.key,
    required this.manager,
    required this.importer,
  });

  final ModelManager manager;
  final ModelImporter importer;

  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  late final DownloadManager _downloads = DownloadManager(
    modelsDir: widget.manager.modelsDir,
    freeBytesAt: widget.importer.freeBytes,
  );
  final Map<String, _EntryUi> _ui = {};
  String? _notice;

  _EntryUi _stateFor(CatalogEntry entry) => _ui.putIfAbsent(entry.id, _EntryUi.new);

  bool _isInstalled(CatalogEntry entry) =>
      widget.manager.models.any((m) => m.fileName == entry.fileName);

  @override
  void dispose() {
    for (final s in _ui.values) {
      s.subscription?.cancel();
    }
    _downloads.close();
    super.dispose();
  }

  Future<void> _start(CatalogEntry entry) async {
    final ui = _stateFor(entry);
    setState(() {
      ui.phase = _Phase.resolving;
      ui.error = null;
    });
    try {
      final resolved = await _downloads.resolve(entry);
      final handle = DownloadHandle();
      ui.handle = handle;
      setState(() {
        ui.phase = _Phase.downloading;
        ui.totalBytes = resolved.liveSizeBytes;
        ui.receivedBytes = _downloads.existingPartialBytes(entry);
      });
      final stream = _downloads.download(entry, resolved, handle: handle);
      ui.subscription = stream.listen(
        (p) => setState(() {
          ui.phase = p.phase == DownloadPhase.verifying
              ? _Phase.verifying
              : _Phase.downloading;
          ui.receivedBytes = p.receivedBytes;
          ui.totalBytes = p.totalBytes;
        }),
        onError: (Object e) async {
          if (e is DownloadCancelledException) {
            setState(() => ui.phase = _Phase.paused);
            return;
          }
          setState(() {
            ui.phase = _Phase.failed;
            ui.error = e.toString();
          });
        },
        onDone: () async {
          if (ui.phase == _Phase.failed || ui.phase == _Phase.paused) return;
          try {
            final model = await widget.manager.registerFile(
              fileName: entry.fileName,
              displayName: entry.displayName,
              profile: entry.profile,
            );
            setState(() {
              ui.phase = _Phase.done;
              _notice =
                  '${model.displayName} was downloaded and added to your models. '
                  'Open the Models tab to load it — it was not loaded automatically.';
            });
          } on ModelManagerException catch (e) {
            setState(() {
              ui.phase = _Phase.failed;
              ui.error = e.message;
            });
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      setState(() {
        ui.phase = _Phase.failed;
        ui.error = e.toString();
      });
    }
  }

  void _cancel(CatalogEntry entry) {
    _stateFor(entry).handle?.cancel();
  }

  void _deleteDownload(CatalogEntry entry) {
    setState(() {
      _downloads.deletePartialDownload(entry);
      _ui.remove(entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final compatible = modelCatalog.where((e) => e.compatibility().isCompatible).toList()
      ..sort((a, b) => a.verifiedSizeBytes.compareTo(b.verifiedSizeBytes));
    final recommended = compatible.take(3).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Download AI Models')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_notice != null)
            StatusBanner(
              message: _notice!,
              icon: Icons.info_outline,
              color: Theme.of(context).colorScheme.tertiary,
              onDismiss: () => setState(() => _notice = null),
            ),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Downloading a model contacts huggingface.co to fetch the file. Your chats, '
              'history and reasoning stay on this device either way — nothing about them is '
              'ever sent to a model publisher.',
            ),
          ),
          _Section(
            title: 'Recommended for Your Device',
            entries: recommended,
            builder: _card,
          ),
          _Section(
            title: 'Small Models',
            entries: modelCatalog
                .where((e) => e.tier == ModelTier.small)
                .toList(),
            builder: _card,
          ),
          _Section(
            title: 'Medium Models',
            entries: modelCatalog
                .where((e) => e.tier == ModelTier.medium)
                .toList(),
            builder: _card,
          ),
          _Section(
            title: 'Large Models',
            entries: modelCatalog
                .where((e) => e.tier == ModelTier.large)
                .toList(),
            builder: _card,
          ),
          _Section(
            title: 'Uncensored Models',
            entries: modelCatalog
                .where((e) => e.intendedUse == ModelIntendedUse.uncensored)
                .toList(),
            builder: _card,
          ),
        ],
      ),
    );
  }

  Widget _card(CatalogEntry entry) {
    return _CatalogCard(
      entry: entry,
      ui: _stateFor(entry),
      installed: _isInstalled(entry),
      onDownload: () => _start(entry),
      onCancel: () => _cancel(entry),
      onRetry: () => _start(entry),
      onDeletePartial: () => _deleteDownload(entry),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.entries, required this.builder});

  final String title;
  final List<CatalogEntry> entries;
  final Widget Function(CatalogEntry) builder;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: builder(e),
            ),
        ],
      ),
    );
  }
}

class _CatalogCard extends StatelessWidget {
  const _CatalogCard({
    required this.entry,
    required this.ui,
    required this.installed,
    required this.onDownload,
    required this.onCancel,
    required this.onRetry,
    required this.onDeletePartial,
  });

  final CatalogEntry entry;
  final _EntryUi ui;
  final bool installed;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDeletePartial;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = entry.compatibility();
    final statusColor = result.isCompatible ? scheme.primary : scheme.error;

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
                    entry.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _Badge(
                  text: result.isCompatible ? 'Compatible' : 'Not recommended',
                  color: statusColor,
                ),
              ],
            ),
            Text(
              entry.publisher,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(
              '${entry.repo}\n${entry.fileName}',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Chip(entry.quantization),
                _Chip(entry.parameterCountLabel),
                _Chip(entry.intendedUse.name),
                _Chip('${(entry.verifiedSizeBytes / mib).round()} MB download'),
                if (entry.verifiedFacts != null)
                  _Chip('${entry.verifiedFacts!.nCtxTrain} trained context'),
              ],
            ),
            const SizedBox(height: 8),
            Text(result.message, style: TextStyle(color: statusColor)),
            if (entry.compatibilityNote != null) ...[
              const SizedBox(height: 4),
              Text(
                entry.compatibilityNote!,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${entry.license}. ${entry.licenseNotes}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              entry.testedOnDevice
                  ? 'Loaded and used for real inference on a physical device.'
                  : 'Not yet confirmed loading on a physical device.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    if (installed) {
      return const Text('Already downloaded — open the Models tab to manage it.');
    }
    switch (ui.phase) {
      case _Phase.idle:
        return FilledButton.icon(
          onPressed: onDownload,
          icon: const Icon(Icons.download),
          label: const Text('Download'),
        );
      case _Phase.resolving:
        return const Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('Checking the file…'),
          ],
        );
      case _Phase.downloading:
      case _Phase.verifying:
        final pct = ui.totalBytes > 0 ? (ui.receivedBytes / ui.totalBytes * 100) : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: ui.totalBytes > 0 ? ui.receivedBytes / ui.totalBytes : null,
            ),
            const SizedBox(height: 6),
            Text(
              ui.phase == _Phase.verifying
                  ? 'Verifying integrity…'
                  : '${(ui.receivedBytes / mib).round()} / ${(ui.totalBytes / mib).round()} MB '
                        '(${pct.toStringAsFixed(0)}%)',
            ),
            const SizedBox(height: 6),
            if (ui.phase == _Phase.downloading)
              OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        );
      case _Phase.paused:
        return Row(
          children: [
            FilledButton(onPressed: onRetry, child: const Text('Resume')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onDeletePartial, child: const Text('Delete partial')),
          ],
        );
      case _Phase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ui.error ?? 'The download failed.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: onDeletePartial, child: const Text('Delete partial')),
              ],
            ),
          ],
        );
      case _Phase.done:
        return const Text('Downloaded. Open the Models tab to load it.');
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}
