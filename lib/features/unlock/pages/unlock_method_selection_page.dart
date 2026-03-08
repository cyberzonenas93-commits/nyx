import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import 'pin_setup_page.dart';
import 'pattern_setup_page.dart';

/// Screen to choose unlock method: PIN or Pattern (first-time setup after onboarding).
class UnlockMethodSelectionPage extends StatelessWidget {
  const UnlockMethodSelectionPage({super.key});

  void _navigateTo(BuildContext context, Widget page) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (context) => page),
      );
    } else {
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => page),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        appBar: AppBar(
          title: const Text('Set up unlock'),
          backgroundColor: AppTheme.surface,
          elevation: 0,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Text(
                  'Choose how you want to unlock your vault',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.8),
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 24),
                _MethodOption(
                  icon: Icons.pin_outlined,
                  title: 'PIN',
                  description: '6-digit numeric code',
                  onTap: () => _navigateTo(context, const PinSetupPage()),
                ),
                const SizedBox(height: 12),
                _MethodOption(
                  icon: Icons.gesture_outlined,
                  title: 'Pattern',
                  description: 'Draw a pattern on the grid',
                  onTap: () => _navigateTo(context, const PatternSetupPage()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MethodOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  
  const _MethodOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppTheme.surface,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: AppTheme.accent,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.text.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: AppTheme.text.withOpacity(0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
