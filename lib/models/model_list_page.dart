import 'package:flutter/material.dart';

import '../engines/media_engines.dart';
import 'memory_estimator.dart';
import 'model_importer.dart';
import 'model_manager.dart';
import 'model_profile.dart';
import 'model_registry.dart';

/// Foundation for the model management screen: list installed models, import
/// a GGUF through the system picker, activate, deactivate, delete, and clear
/// quarantine. Chat and the final navigation come later.
class ModelListPage extends StatefulWidget {
  const ModelListPage({
    super.key,
    required this.manager,
    this.importer,
    this.imageEngine = const ComingSoonImageEngine(),
    this.videoEngine = const ComingSoonVideoEngine(),
  });

  final ModelManager manager;

  /// Null in tests, where importing is not available.
  final ModelImporter? importer;

  final ImageEngine imageEngine;
  final VideoEngine videoEngine;

  @override
  State<ModelListPage> createState() => _ModelListPageState();
}

class _ModelListPageState extends State<ModelListPage> {
  String? _message;
  bool _busy = false;

  ModelManager get _mgr => widget.manager;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on ModelManagerException catch (e) {
      _message = e.message;
    } catch (e) {
      _message = 'Error: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final importer = widget.importer;
    if (importer == null) return;
    final profile = await _pickProfile();
    if (profile == null) return;
    await _run(() async {
      final picked = await importer.pickAndCopy();
      if (picked == null) return;
      final model = await _mgr.registerFile(
        fileName: picked.fileName,
        displayName: picked.displayName,
        profile: profile,
      );
      _message = 'Imported ${model.displayName}';
    });
    if (mounted) setState(() {});
  }

  Future<ModelProfile?> _pickProfile() {
    return showDialog<ModelProfile>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Use this model for'),
        children: [
          for (final p in allProfiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p),
              child: Text(p.displayName),
            ),
        ],
      ),
    );
  }

  Future<void> _delete(InstalledModel model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text('${model.displayName} will be removed from this phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => _mgr.delete(model.id));
    if (mounted) setState(() {});
  }

  Future<void> _activate(InstalledModel model) async {
    final profile = profileById(model.profileId) ?? chatProfile;
    await _run(() async {
      final report = await _mgr.activate(model.id, profile: profile);
      _message =
          'Loaded ${report.model.displayName} with ${report.contextTokens} tokens of context'
          '${report.contextClamped ? ' (reduced to fit memory)' : ''}';
    });
    if (mounted) setState(() {});
  }

  Future<void> _deactivate() async {
    await _run(_mgr.deactivate);
    if (mounted) setState(() {});
  }

  void _clearQuarantine(InstalledModel model) {
    _mgr.clearQuarantine(model.id);
    setState(() => _message = 'Quarantine cleared for ${model.displayName}');
  }

  @override
  Widget build(BuildContext context) {
    final models = _mgr.models;
    final active = _mgr.active;
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      floatingActionButton: widget.importer == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.file_open),
              label: const Text('Import GGUF'),
            ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_message!),
            ),
          if (models.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No models yet. Import a GGUF file to get started.'),
            ),
          for (final m in models)
            _ModelTile(
              model: m,
              isActive: active?.id == m.id,
              busy: _busy,
              onActivate: () => _activate(m),
              onDeactivate: _deactivate,
              onDelete: () => _delete(m),
              onClearQuarantine: () => _clearQuarantine(m),
            ),
          const SizedBox(height: 24),
          const Text('Image', style: TextStyle(fontWeight: FontWeight.bold)),
          ListTile(title: Text(widget.imageEngine.status)),
          const Text('Video', style: TextStyle(fontWeight: FontWeight.bold)),
          ListTile(title: Text(widget.videoEngine.status)),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.isActive,
    required this.busy,
    required this.onActivate,
    required this.onDeactivate,
    required this.onDelete,
    required this.onClearQuarantine,
  });

  final InstalledModel model;
  final bool isActive;
  final bool busy;
  final VoidCallback onActivate;
  final VoidCallback onDeactivate;
  final VoidCallback onDelete;
  final VoidCallback onClearQuarantine;

  @override
  Widget build(BuildContext context) {
    final profile = profileById(model.profileId);
    final estimate = estimateMemory(
      model.facts,
      profile?.defaultContext ?? MemoryPolicy.minContextTokens,
    );
    final status = model.isQuarantined
        ? 'Quarantined: ${model.quarantineReason}'
        : isActive
        ? 'Loaded'
        : 'Not loaded';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              model.displayName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(profile?.displayName ?? 'Unassigned profile'),
            Text(
              '${(model.sizeBytes / mib).toStringAsFixed(0)} MB file, '
              '~${(estimate.total / mib).toStringAsFixed(0)} MB estimated RAM at default context',
            ),
            Text(status),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (model.isQuarantined)
                  OutlinedButton(
                    onPressed: busy ? null : onClearQuarantine,
                    child: const Text('Clear quarantine'),
                  )
                else if (isActive)
                  OutlinedButton(
                    onPressed: busy ? null : onDeactivate,
                    child: const Text('Unload'),
                  )
                else
                  FilledButton(
                    onPressed: busy ? null : onActivate,
                    child: const Text('Load'),
                  ),
                TextButton(
                  onPressed: busy ? null : onDelete,
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
