import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../../app/theme.dart';

/// Full-featured photo viewer with zoom and pan
class PhotoViewerWidget extends StatefulWidget {
  final Uint8List? imageData; // Legacy - prefer imageFile
  final File? imageFile; // Path-first design
  final String? title;
  final Widget Function()? metadataBuilder;
  final VoidCallback? onDismiss; // Called when user swipes down to close
  final ValueChanged<bool>? onFullscreenChanged; // Called when fullscreen toggles
  
  const PhotoViewerWidget({
    super.key,
    this.imageData,
    this.imageFile,
    this.title,
    this.metadataBuilder,
    this.onDismiss,
    this.onFullscreenChanged,
  }) : assert(imageData != null || imageFile != null, 'Either imageData or imageFile must be provided');
  
  @override
  State<PhotoViewerWidget> createState() => _PhotoViewerWidgetState();
}

class _PhotoViewerWidgetState extends State<PhotoViewerWidget> {
  final TransformationController _transformationController = TransformationController();
  bool _showControls = true;
  bool _showMetadata = false;
  bool _isFullscreen = false;

  // Dismiss gesture tracking
  double _dismissOffset = 0.0;
  bool _isDismissing = false;
  double _dismissOpacity = 1.0;
  double _dismissScale = 1.0;
  DateTime? _dismissStartTime;
  double _gestureStartY = 0.0;
  double _gestureStartX = 0.0;
  
  @override
  void dispose() {
    // Ensure we leave immersive mode if user navigates away while fullscreen.
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError((_) => null);
      widget.onFullscreenChanged?.call(false);
    }
    _transformationController.dispose();
    super.dispose();
  }

  void _setFullscreen(bool value) {
    if (_isFullscreen == value) return;
    _isFullscreen = value;
    widget.onFullscreenChanged?.call(_isFullscreen);

    // Immersive mode removes status/navigation bars for a true fullscreen view.
    // Restore edge-to-edge when exiting so the rest of the app behaves normally.
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky).catchError((_) => null);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).catchError((_) => null);
    }
  }

  void _toggleFullscreen() {
    final nextFullscreen = !_isFullscreen;
    setState(() {
      _showMetadata = false; // Hide metadata in fullscreen
      _showControls = nextFullscreen ? false : true; // Enter fullscreen with controls hidden
    });
    _setFullscreen(nextFullscreen);
    if (!nextFullscreen) {
      _hideControlsAfterDelay();
    }
  }

  bool _isZoomedIn() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    return scale > 1.02;
  }
  
  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
    setState(() {
      _showControls = true;
    });
    _hideControlsAfterDelay();
  }
  
  void _hideControlsAfterDelay() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }
  
  void _toggleMetadata() {
    setState(() {
      _showMetadata = !_showMetadata;
      _showControls = true;
    });
    if (!_showMetadata) {
      _hideControlsAfterDelay();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Photo viewer
        Expanded(
          child: AnimatedContainer(
            duration: _isDismissing ? Duration.zero : const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            transform: Matrix4.identity()
              ..translateByDouble(0.0, _dismissOffset, 0.0, 1.0)
              ..scaleByDouble(_dismissScale, _dismissScale, 1.0, 1.0),
            child: Opacity(
              opacity: _dismissOpacity,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  setState(() {
                    _showControls = !_showControls;
                  });
                  if (_showControls) {
                    _hideControlsAfterDelay();
                  }
                },
                onDoubleTap: _toggleFullscreen,
                onVerticalDragStart: (details) {
                  if (widget.onDismiss == null) return;
                  if (_isZoomedIn()) return; // Don't fight pan gestures when zoomed
                  _gestureStartY = details.localPosition.dy;
                  _gestureStartX = details.localPosition.dx;
                  _dismissStartTime = DateTime.now();
                },
                onVerticalDragUpdate: (details) {
                  if (widget.onDismiss == null) return;
                  if (_isZoomedIn()) return;

                  final deltaY = details.localPosition.dy - _gestureStartY;
                  final deltaX = details.localPosition.dx - _gestureStartX;
                  final isMostlyVertical = deltaY.abs() > deltaX.abs() * 1.5;
                  final isDownward = deltaY > 0;

                  if (!isMostlyVertical || !isDownward) return;
                  if (deltaY < 25) return; // ignore tiny jitters

                  final screenHeight = MediaQuery.of(context).size.height;
                  _isDismissing = true;
                  _dismissOffset = deltaY;

                  final dragProgress = (deltaY / screenHeight).clamp(0.0, 1.0);
                  _dismissOpacity = 1.0 - (dragProgress * 0.6);
                  _dismissScale = 1.0 - (dragProgress * 0.12);

                  if (mounted) setState(() {});
                },
                onVerticalDragEnd: (details) {
                  if (widget.onDismiss == null) return;
                  if (!_isDismissing) {
                    _dismissStartTime = null;
                    return;
                  }

                  final screenHeight = MediaQuery.of(context).size.height;
                  final dragProgress = (_dismissOffset / screenHeight).clamp(0.0, 1.0);

                  // Simple velocity estimate (px/ms) using elapsed time.
                  double velocity = 0.0;
                  final start = _dismissStartTime;
                  if (start != null) {
                    final ms = DateTime.now().difference(start).inMilliseconds;
                    if (ms > 0) velocity = _dismissOffset / ms;
                  }

                  const absoluteThreshold = 110.0;
                  const relativeThreshold = 0.15;
                  const velocityThreshold = 0.6;
                  const minVelocityDistance = 60.0;

                  final shouldDismiss = dragProgress > relativeThreshold ||
                      _dismissOffset > absoluteThreshold ||
                      (velocity > velocityThreshold && _dismissOffset > minVelocityDistance);

                  if (shouldDismiss) {
                    widget.onDismiss?.call();
                    return;
                  }

                  // Snap back
                  _isDismissing = false;
                  _dismissOffset = 0.0;
                  _dismissOpacity = 1.0;
                  _dismissScale = 1.0;
                  _dismissStartTime = null;
                  if (mounted) setState(() {});
                },
                child: Stack(
                  children: [
                // Image viewer (path-first: use Image.file when available)
                InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Center(
                    child: widget.imageFile != null
                        ? Image.file(
                            widget.imageFile!,
                            fit: BoxFit.contain,
                            cacheWidth: null, // Full resolution for zoom
                            errorBuilder: (context, error, stackTrace) {
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.error_outline,
                                      size: 64,
                                      color: AppTheme.warning,
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      'Failed to load image',
                                      style: TextStyle(color: AppTheme.text),
                                    ),
                                  ],
                                ),
                              );
                            },
                          )
                        : Image.memory(
                            widget.imageData!,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.error_outline,
                                      size: 64,
                                      color: AppTheme.warning,
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      'Failed to load image',
                                      style: TextStyle(color: AppTheme.text),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ),
                
                // Controls overlay
                if (_showControls && !_isFullscreen)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.7),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: SafeArea(
                        child: Row(
                          children: [
                            if (widget.title != null)
                              Expanded(
                                child: Text(
                                  widget.title!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (widget.metadataBuilder != null)
                              IconButton(
                                icon: Icon(
                                  _showMetadata ? Icons.info : Icons.info_outline,
                                  color: Colors.white,
                                ),
                                onPressed: _toggleMetadata,
                                tooltip: _showMetadata ? 'Hide details' : 'Show details',
                              ),
                            IconButton(
                              icon: const Icon(Icons.zoom_out_map, color: Colors.white),
                              onPressed: _resetZoom,
                              tooltip: 'Reset zoom',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Metadata - only show when user taps details button
        if (_showMetadata && widget.metadataBuilder != null && !_isFullscreen)
          widget.metadataBuilder!(),
      ],
    );
  }
}
