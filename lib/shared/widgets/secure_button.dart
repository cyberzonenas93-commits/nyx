import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/theme.dart';

/// Premium secure button with glowing accent and haptic feedback
class SecureButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final bool isLoading;
  final IconData? icon;
  
  const SecureButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isPrimary = true,
    this.isLoading = false,
    this.icon,
  });
  
  @override
  State<SecureButton> createState() => _SecureButtonState();
}

class _SecureButtonState extends State<SecureButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    
    _glowAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  Future<void> _handleTap() async {
    if (widget.onPressed != null) {
      widget.onPressed!();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glowAnimation,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            boxShadow: widget.isPrimary && widget.onPressed != null
                ? [
                    BoxShadow(
                      color: AppTheme.accent.withOpacity(_glowAnimation.value * 0.3),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: ElevatedButton(
            onPressed: (widget.isLoading || widget.onPressed == null) ? null : _handleTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.isPrimary ? AppTheme.accent : AppTheme.surfaceVariant,
              foregroundColor: widget.isPrimary ? AppTheme.primary : AppTheme.text,
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
            ),
            child: widget.isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, size: 20),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          widget.text,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
