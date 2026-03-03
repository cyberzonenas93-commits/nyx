import 'package:flutter/material.dart';
import '../../../app/theme.dart';

/// Tutorial step definition
class TutorialStep {
  final String id;
  final String title;
  final String description;
  final GlobalKey? targetKey;
  final Alignment alignment;
  final bool showSkipButton;
  final bool showNextButton;
  final bool showPreviousButton;
  final VoidCallback? onStepComplete;
  
  TutorialStep({
    required this.id,
    required this.title,
    required this.description,
    this.targetKey,
    this.alignment = Alignment.center,
    this.showSkipButton = true,
    this.showNextButton = true,
    this.showPreviousButton = true,
    this.onStepComplete,
  });
}

/// Interactive tutorial overlay widget
class TutorialOverlay extends StatefulWidget {
  final List<TutorialStep> steps;
  final int currentStep;
  final Function(int) onStepChanged;
  final VoidCallback onComplete;
  final VoidCallback onSkip;
  
  const TutorialOverlay({
    super.key,
    required this.steps,
    required this.currentStep,
    required this.onStepChanged,
    required this.onComplete,
    required this.onSkip,
  });
  
  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  @override
  Widget build(BuildContext context) {
    if (widget.currentStep >= widget.steps.length) {
      return const SizedBox.shrink();
    }
    
    final step = widget.steps[widget.currentStep];
    final targetContext = step.targetKey?.currentContext;
    
    return Stack(
      children: [
        // Dark overlay with cutout
        _buildOverlay(targetContext),
        // Tutorial content
        _buildTutorialContent(step, targetContext),
      ],
    );
  }
  
  Widget _buildOverlay(BuildContext? targetContext) {
    final screenSize = MediaQuery.of(context).size;
    const padding = 8.0;
    Rect? cutout;
    if (targetContext != null) {
      final renderObject = targetContext!.findRenderObject();
      if (renderObject != null && renderObject is RenderBox && renderObject.hasSize) {
        final position = renderObject.localToGlobal(Offset.zero);
        final size = renderObject.size;
        cutout = Rect.fromLTWH(
          position.dx - padding,
          position.dy - padding,
          size.width + padding * 2,
          size.height + padding * 2,
        );
      }
    }

    final overlayColor = Colors.black.withOpacity(0.75);
    if (cutout == null) {
      return GestureDetector(
        onTap: () {},
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: overlayColor,
        ),
      );
    }

    // Build four panels around the cutout so the cutout area has no widget and taps pass through (e.g. to the lock button).
    return Stack(
      children: [
        _overlayPanel(0, 0, cutout.left, screenSize.height, overlayColor),
        _overlayPanel(cutout.left, 0, cutout.width, cutout.top, overlayColor),
        _overlayPanel(cutout.right, 0, screenSize.width - cutout.right, screenSize.height, overlayColor),
        _overlayPanel(cutout.left, cutout.bottom, cutout.width, screenSize.height - cutout.bottom, overlayColor),
        // Highlight border around cutout (IgnorePointer so taps still pass through to target)
        Positioned(
          left: cutout.left,
          top: cutout.top,
          width: cutout.width,
          height: cutout.height,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accent, width: 3),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _overlayPanel(double left, double top, double width, double height, Color color) {
    if (width <= 0 || height <= 0) return const SizedBox.shrink();
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: () {},
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(color: color),
      ),
    );
  }
  
  Widget _buildTutorialContent(TutorialStep step, BuildContext? targetContext) {
    // Calculate position for tutorial card
    Offset? targetPosition;
    Size? targetSize;
    
    if (targetContext != null) {
      final renderObject = targetContext!.findRenderObject();
      if (renderObject != null && renderObject is RenderBox) {
        final renderBox = renderObject;
        if (renderBox.attached && renderBox.hasSize) {
          final position = renderBox.localToGlobal(Offset.zero);
          final size = renderBox.size;
          targetPosition = position;
          targetSize = size;
        }
      }
    }
    
    // Determine card position
    Alignment cardAlignment = step.alignment;
    if (targetPosition != null && targetSize != null) {
      final screenSize = MediaQuery.of(context).size;
      final targetCenter = Offset(
        targetPosition.dx + targetSize.width / 2,
        targetPosition.dy + targetSize.height / 2,
      );
      
      // Position card above or below target based on available space
      if (targetCenter.dy < screenSize.height / 2) {
        cardAlignment = Alignment.topCenter;
      } else {
        cardAlignment = Alignment.bottomCenter;
      }
    }
    
    return Positioned.fill(
      child: Align(
        alignment: cardAlignment,
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.surface,
                    AppTheme.surfaceVariant,
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppTheme.accent.withOpacity(0.3),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.accent.withOpacity(0.3),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Step indicator
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppTheme.accent,
                              AppTheme.accentVariant,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Step ${widget.currentStep + 1} of ${widget.steps.length}',
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: widget.onSkip,
                        color: AppTheme.text.withOpacity(0.6),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Title
                  Text(
                    step.title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.text,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Description
                  Text(
                    step.description,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppTheme.text.withOpacity(0.8),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Action buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (step.showSkipButton && widget.currentStep == 0)
                        TextButton(
                          onPressed: widget.onSkip,
                          child: Text(
                            'Skip Tutorial',
                            style: TextStyle(
                              color: AppTheme.text.withOpacity(0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (step.showPreviousButton && widget.currentStep > 0) ...[
                        TextButton(
                          onPressed: () {
                            widget.onStepChanged(widget.currentStep - 1);
                          },
                          child: const Text(
                            'Previous',
                            style: TextStyle(
                              color: AppTheme.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppTheme.accent,
                              AppTheme.accentVariant,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accent.withOpacity(0.4),
                              blurRadius: 8,
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: () {
                            if (step.onStepComplete != null) {
                              step.onStepComplete!();
                            }
                            
                            if (widget.currentStep < widget.steps.length - 1) {
                              widget.onStepChanged(widget.currentStep + 1);
                            } else {
                              widget.onComplete();
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            widget.currentStep < widget.steps.length - 1
                                ? 'Next'
                                : 'Got it!',
                            style: const TextStyle(
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom painter for tutorial overlay with cutout
class TutorialOverlayPainter extends CustomPainter {
  final BuildContext? targetContext;
  final Color overlayColor;
  
  TutorialOverlayPainter({
    required this.targetContext,
    required this.overlayColor,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    // Fill entire canvas with overlay color
    final overlayPaint = Paint()..color = overlayColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), overlayPaint);
    
    // Cut out target area if available
    if (targetContext != null) {
      final renderObject = targetContext!.findRenderObject();
      if (renderObject != null && renderObject is RenderBox) {
        final renderBox = renderObject;
        if (renderBox.attached && renderBox.hasSize) {
          final position = renderBox.localToGlobal(Offset.zero);
          final targetSize = renderBox.size;
          
          // Create rounded rectangle cutout with padding
          const padding = 8.0;
          final cutoutRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(
              position.dx - padding,
              position.dy - padding,
              targetSize.width + (padding * 2),
              targetSize.height + (padding * 2),
            ),
            const Radius.circular(12),
          );
          
          // Use blend mode to cut out the area
          final cutoutPaint = Paint()
            ..color = Colors.transparent
            ..blendMode = BlendMode.clear;
          
          canvas.drawRRect(cutoutRect, cutoutPaint);
          
          // Draw highlight border
          final borderPaint = Paint()
            ..color = AppTheme.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3;
          
          canvas.drawRRect(cutoutRect, borderPaint);
        }
      }
    }
  }
  
  @override
  bool shouldRepaint(TutorialOverlayPainter oldDelegate) {
    return oldDelegate.targetContext != targetContext ||
           oldDelegate.overlayColor != overlayColor;
  }
}
