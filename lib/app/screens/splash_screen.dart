import 'dart:async';

import 'package:flutter/material.dart';

/// Brand splash shown on every start. It depends only on a timer, so it shows the same way
/// with or without a model, network, chat history, or GGUF file.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.onDone,
    this.duration = const Duration(milliseconds: 1600),
  });

  final VoidCallback onDone;
  final Duration duration;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF050A24);
    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/image/softdigi_ai_logo.png',
                width: 200,
                height: 200,
                fit: BoxFit.contain,
                semanticLabel: 'SoftDigi AI logo',
              ),
              const SizedBox(height: 24),
              const Text(
                'SoftDigi AI',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Powered by SoftDigi Technology',
                style: TextStyle(color: Color(0xFFAAC8FF), fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
