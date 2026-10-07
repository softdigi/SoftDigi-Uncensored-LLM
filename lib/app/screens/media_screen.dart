import 'package:flutter/material.dart';

import '../../engines/media_engines.dart';

/// Image and Video. Placeholders only: no image or video inference is shipped yet.
class MediaScreen extends StatelessWidget {
  const MediaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Image & Video')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ComingSoonCard(
            icon: Icons.image_outlined,
            title: 'Image',
            status: const ComingSoonImageEngine().status,
            description: 'Create and edit images on your phone.',
          ),
          const SizedBox(height: 12),
          _ComingSoonCard(
            icon: Icons.movie_outlined,
            title: 'Video',
            status: const ComingSoonVideoEngine().status,
            description: 'Generate and edit short videos on your phone.',
          ),
          const SizedBox(height: 24),
          Text(
            'These features will appear here when they are ready.',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ComingSoonCard extends StatelessWidget {
  const _ComingSoonCard({
    required this.icon,
    required this.title,
    required this.status,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String status;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, size: 36, color: scheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                status,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
