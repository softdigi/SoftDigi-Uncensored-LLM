import 'package:flutter/material.dart';

import '../../chat/chat_store.dart';
import '../app_controller.dart';
import '../widgets/common.dart';

/// Saved chats, newest first. Tap a chat to open it. Chats are stored on this device only.
class ChatHistoryScreen extends StatelessWidget {
  const ChatHistoryScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _deleteOne(BuildContext context, Conversation c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text(
          '"${c.title}" will be removed from this phone. Your models are not affected.',
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
    if (ok == true) controller.deleteConversation(c.id);
  }

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all chats?'),
        content: const Text('Delete all chat history? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (ok == true) controller.deleteAllConversations();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final chats = controller.history;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Chat history'),
            actions: [
              if (chats.isNotEmpty)
                IconButton(
                  tooltip: 'Delete all chats',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: controller.generating
                      ? null
                      : () => _deleteAll(context),
                ),
            ],
          ),
          body: Column(
            children: [
              if (controller.errorMessage != null)
                StatusBanner(
                  message: controller.errorMessage!,
                  icon: Icons.error_outline,
                  color: theme.colorScheme.error,
                  onDismiss: controller.dismissError,
                ),
              Expanded(
                child: chats.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'No saved chats yet. Your conversations will appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        itemCount: chats.length,
                        itemBuilder: (context, i) {
                          final c = chats[i];
                          final modelName = controller.modelNameFor(c.modelId);
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                child: Icon(
                                  profileIsCoding(c.profileId)
                                      ? Icons.code
                                      : Icons.chat_bubble_outline,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                              title: Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${formatWhen(c.updatedAt)} · '
                                '${modelName ?? 'Model no longer installed'}',
                                style: TextStyle(
                                  color: modelName == null
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: 'Delete chat',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: controller.generating
                                    ? null
                                    : () => _deleteOne(context, c),
                              ),
                              onTap: controller.generating
                                  ? null
                                  : () {
                                      controller.openConversation(c.id);
                                      Navigator.of(context).pop();
                                    },
                            ),
                          );
                        },
                      ),
              ),
              const _PrivacyFooter(),
            ],
          ),
        );
      },
    );
  }
}

/// Privacy statement and company line, shown under the history list.
class _PrivacyFooter extends StatelessWidget {
  const _PrivacyFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 12.5,
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Your chat history is stored locally on this device and is not uploaded to a server.',
              textAlign: TextAlign.center,
              style: muted,
            ),
            const SizedBox(height: 6),
            Text(
              'SoftDigi AI · SoftDigi Technology\nYour AI. Your Device. Your Privacy.',
              textAlign: TextAlign.center,
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}
