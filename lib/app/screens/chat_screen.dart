import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/model_profile.dart';
import '../../search/search_mode.dart';
import '../../search/search_result.dart';
import '../app_controller.dart';
import '../widgets/common.dart';
import 'chat_history_screen.dart';
import '../widgets/message_content.dart';

/// The primary screen: conversation with the loaded model.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    required this.onOpenModels,
  });

  final AppController controller;
  final VoidCallback onOpenModels;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the newest text in view while a reply streams in.
  void _onChanged() {
    if (!mounted) return;
    final count = _c.messages.length;
    final grew = count != _lastCount;
    _lastCount = count;
    if (!_scroll.hasClients) return;
    if (grew || _c.generating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final target = _scroll.position.maxScrollExtent;
        if (grew) {
          _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        } else if (_scroll.position.pixels > target - 80) {
          _scroll.jumpTo(target);
        }
      });
    }
  }

  /// Explains why the open chat cannot take a message, or null when it can.
  String? get _access {
    switch (_c.access) {
      case ChatAccess.needsLoad:
        return 'Load ${_c.requiredModelName ?? 'this chat’s model'} to continue this chat.';
      case ChatAccess.modelMissing:
        return 'The model for this chat is no longer installed. You can read this chat, or start a new one.';
      case ChatAccess.newChat:
      case ChatAccess.ready:
        return null;
    }
  }

  Future<void> _pickSearchMode(BuildContext context) async {
    final mode = await chooseSearchMode(context, _c.searchMode);
    if (mode != null) _c.setSearchMode(mode);
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatHistoryScreen(controller: _c),
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _c.generating || !_c.canChat) return;
    _input.clear();
    await _c.send(text);
  }

  Future<void> _newChat() async {
    if (_c.messages.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a new chat?'),
        content: const Text('The current conversation will be cleared.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('New chat'),
          ),
        ],
      ),
    );
    if (ok == true) _c.newChat();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final model = _c.loadedModel;
        final profile = _c.loadedProfile;
        return Scaffold(
          appBar: AppBar(
            title: const Text('SoftDigi AI'),
            actions: [
              IconButton(
                tooltip: 'Chat history',
                icon: const Icon(Icons.history),
                onPressed: _c.generating ? null : _openHistory,
              ),
              IconButton(
                tooltip: 'New chat',
                icon: const Icon(Icons.edit_square),
                onPressed: _c.messages.isEmpty || _c.generating
                    ? null
                    : _newChat,
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(28),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 8, bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _ModelIndicator(
                        model: model?.displayName,
                        profile: profile?.role,
                        contextTokens: _c.loadedContextTokens,
                        onTap: widget.onOpenModels,
                      ),
                    ),
                    _SearchModeIndicator(
                      mode: _c.searchMode,
                      configured: _c.webSearchConfigured,
                      onTap: () => _pickSearchMode(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (_c.busy)
                  StatusBanner(
                    message: _c.busyMessage ?? 'Please wait…',
                    icon: Icons.hourglass_top,
                    color: theme.colorScheme.primary,
                    progress: true,
                  ),
                if (_c.errorMessage != null)
                  StatusBanner(
                    message: _c.errorMessage!,
                    icon: Icons.error_outline,
                    color: theme.colorScheme.error,
                    onDismiss: _c.dismissError,
                  ),
                if (_c.notice != null)
                  StatusBanner(
                    message: _c.notice!,
                    icon: Icons.info_outline,
                    color: theme.colorScheme.tertiary,
                    onDismiss: _c.dismissNotice,
                  ),
                if (_access != null)
                  StatusBanner(
                    message: _access!,
                    icon: Icons.lock_clock_outlined,
                    color: theme.colorScheme.secondary,
                  ),
                if (_c.awaitingSearchPermission)
                  _SearchPermissionBanner(
                    query: _c.pendingSearchQuery ?? '',
                    onAllow: () => _c.respondToSearchPrompt(true),
                    onCancel: () => _c.respondToSearchPrompt(false),
                  ),
                Expanded(child: _messageArea(context)),
                _InputBar(
                  controller: _input,
                  generating: _c.generating,
                  enabled:
                      _c.canChat && !_c.busy && !_c.awaitingSearchPermission,
                  onSend: _send,
                  onStop: _c.stopGeneration,
                  hint: _c.canChat
                      ? 'Message'
                      : _access == null
                      ? 'Load a model to start chatting'
                      : 'This chat cannot be continued',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _messageArea(BuildContext context) {
    final messages = _c.messages;
    if (messages.isEmpty) {
      return _EmptyChat(
        hasModels: _c.hasModels,
        loaded: _c.canChat,
        onOpenModels: widget.onOpenModels,
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: messages.length,
      itemBuilder: (context, i) => _Bubble(message: messages[i]),
    );
  }
}

class _ModelIndicator extends StatelessWidget {
  const _ModelIndicator({
    required this.model,
    required this.profile,
    required this.contextTokens,
    required this.onTap,
  });

  final String? model;
  final ModelRole? profile;
  final int? contextTokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loaded = model != null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              loaded ? Icons.circle : Icons.circle_outlined,
              size: 9,
              color: loaded ? scheme.primary : scheme.outline,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                loaded
                    ? '$model${contextTokens == null ? '' : ' · $contextTokens tokens'}'
                    : 'No model loaded',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows whether the network is reachable at all in the current mode: 🔒
/// Local Only (never), or 🌐 (possible, gated by the mode's own rules).
class _SearchModeIndicator extends StatelessWidget {
  const _SearchModeIndicator({
    required this.mode,
    required this.configured,
    required this.onTap,
  });

  final SearchMode mode;
  final bool configured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final networkCapable = mode != SearchMode.localOnly;
    final label = !configured
        ? 'Web Search not set up'
        : searchModeLabel(mode);
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                networkCapable && configured
                    ? Icons.public
                    : Icons.lock_outline,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                networkCapable && configured ? 'Web' : 'Local',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "🌐 Web Search is needed for current information. Allow?" prompt. No
/// network request happens until the user taps Allow.
class _SearchPermissionBanner extends StatelessWidget {
  const _SearchPermissionBanner({
    required this.query,
    required this.onAllow,
    required this.onCancel,
  });

  final String query;
  final VoidCallback onAllow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.public, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Web Search is needed for current information. Allow?',
                      style: TextStyle(color: scheme.onTertiaryContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: onAllow, child: const Text('Allow')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.hasModels,
    required this.loaded,
    required this.onOpenModels,
  });

  final bool hasModels;
  final bool loaded;
  final VoidCallback onOpenModels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String title;
    final String body;
    if (!hasModels) {
      title = 'Add a model to begin';
      body = 'Import a GGUF model from the Models tab.';
    } else if (!loaded) {
      title = 'Load a model to begin';
      body = 'Choose a model in the Models tab and tap Load.';
    } else {
      title = 'What would you like to ask?';
      body = 'Everything runs on this phone.';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 44,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (!loaded) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onOpenModels,
                child: const Text('Go to Models'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatBubble message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;
    final background = isUser
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = isUser ? scheme.onPrimaryContainer : scheme.onSurface;

    final content = message.text.isEmpty && message.streaming
        ? const _Typing()
        : MessageContent(text: message.text, color: foreground);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: message.text.isEmpty
            ? null
            : () {
                Clipboard.setData(ClipboardData(text: message.text));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Copied')));
              },
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isUser ? 18 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 18),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                content,
                if (message.sources.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _SourcesList(sources: message.sources),
                ],
                if (message.error != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 16, color: scheme.error),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          message.error!,
                          style: TextStyle(color: scheme.error, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sources a reply used, shown under the bubble. Tapping does nothing
/// yet — URLs are shown as plain text, not launched, so the app never needs
/// a url_launcher dependency or leaves the chat screen.
class _SourcesList extends StatelessWidget {
  const _SourcesList({required this.sources});

  final List<SearchResult> sources;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.public, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              'Sources',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        for (final s in sources)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '${s.title}\n${s.url}',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(
          3,
          (_) => Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outline,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.generating,
    required this.enabled,
    required this.onSend,
    required this.onStop,
    required this.hint,
  });

  final TextEditingController controller;
  final bool generating;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled && !generating,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(hintText: hint),
              ),
            ),
            const SizedBox(width: 8),
            if (generating)
              IconButton.filled(
                tooltip: 'Stop',
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded),
              )
            else
              IconButton.filled(
                tooltip: 'Send',
                onPressed: enabled ? onSend : null,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
          ],
        ),
      ),
    );
  }
}
