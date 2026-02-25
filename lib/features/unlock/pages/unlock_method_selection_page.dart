import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../app/theme.dart';
import 'pin_setup_page.dart';

/// Screen that redirects directly to PIN setup (pattern unlock removed)
class UnlockMethodSelectionPage extends StatelessWidget {
  const UnlockMethodSelectionPage({super.key});
  
  @override
  Widget build(BuildContext context) {
    // Navigate immediately to PIN setup - don't wait for post-frame callback
    // This prevents infinite loading issues on macOS
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = Navigator.of(context);
      if (!navigator.mounted) return;
      
      if (navigator.canPop()) {
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (context) => const PinSetupPage(),
          ),
        );
      } else {
        // If we can't pop, use pushAndRemoveUntil to clear the stack
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const PinSetupPage(),
          ),
          (route) => false,
        );
      }
    });
    
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // Allow going back to subscription setup during onboarding
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        body: const Center(
          child: CircularProgressIndicator(
            color: AppTheme.accent,
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
