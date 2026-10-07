import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_theme.dart';
import 'screens/chat_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/first_launch_screen.dart';
import 'screens/media_screen.dart';
import 'screens/models_screen.dart';

/// Root widget of the SoftDigi AI app.
class SoftLocalPaiApp extends StatelessWidget {
  const SoftLocalPaiApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoftDigi AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: _StartupGate(controller: controller),
    );
  }
}

/// Chooses the first screen. With no installed model, the first-launch screen
/// explains the app and asks for a model. Otherwise it shows the main tabs.
/// Shows the brand splash first, then the app. Nothing here waits for the model or storage.
class _StartupGate extends StatefulWidget {
  const _StartupGate({required this.controller});

  final AppController controller;

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool _splashDone = false;

  @override
  Widget build(BuildContext context) {
    if (!_splashDone) {
      return SplashScreen(onDone: () => setState(() => _splashDone = true));
    }
    return AppShell(controller: widget.controller);
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.hasModels) {
          return FirstLaunchScreen(controller: c);
        }
        return Scaffold(
          body: IndexedStack(
            index: _tab,
            children: [
              ChatScreen(
                controller: c,
                onOpenModels: () => setState(() => _tab = 1),
              ),
              ModelsScreen(controller: c),
              const MediaScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Chat',
              ),
              NavigationDestination(
                icon: Icon(Icons.memory_outlined),
                selectedIcon: Icon(Icons.memory),
                label: 'Models',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                selectedIcon: Icon(Icons.auto_awesome),
                label: 'Image & Video',
              ),
            ],
          ),
        );
      },
    );
  }
}
