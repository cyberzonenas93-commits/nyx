import 'package:flutter/material.dart';
import '../../../app/theme.dart';

/// Encodes pattern indices to a stable string for hashing (e.g. [0,1,2,5,8] -> "0-1-2-5-8").
String patternToString(List<int> indices) {
  return indices.join('-');
}

/// Parses pattern string back to list of indices.
List<int> patternFromString(String s) {
  if (s.isEmpty) return [];
  return s.split('-').map((e) => int.tryParse(e) ?? -1).where((e) => e >= 0 && e <= 8).toList();
}

/// Minimum number of dots required in a pattern.
const int kPatternMinLength = 4;

/// 3x3 pattern lock grid. Dots are indexed 0-8 (row-major).
/// [onPatternComplete] is called with the list of indices when user lifts finger
/// (only if length >= [minLength], otherwise [onPatternTooShort] is called).
/// [wrongAttempt]: when true, widget shows error state and clears (parent should set false after ~500ms).
class PatternLockWidget extends StatefulWidget {
  final int minLength;
  final ValueChanged<List<int>> onPatternComplete;
  final VoidCallback? onPatternTooShort;
  final bool wrongAttempt;
  final double size;

  const PatternLockWidget({
    super.key,
    this.minLength = kPatternMinLength,
    required this.onPatternComplete,
    this.onPatternTooShort,
    this.wrongAttempt = false,
    this.size = 280,
  });

  @override
  State<PatternLockWidget> createState() => _PatternLockWidgetState();
}

class _PatternLockWidgetState extends State<PatternLockWidget> {
  final List<int> _selected = [];
  Offset? _currentPosition;

  static const int _count = 9;
  static const int _cols = 3;

  double get _dotRadius => 12.0;
  double get _hitSlop => 24.0;

  @override
  void didUpdateWidget(covariant PatternLockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.wrongAttempt && !oldWidget.wrongAttempt) {
      _selected.clear();
      _currentPosition = null;
    }
  }

  List<Offset> _getDotCenters(Size size) {
    final cellWidth = size.width / _cols;
    final cellHeight = size.height / _cols;
    final centers = <Offset>[];
    for (int i = 0; i < _count; i++) {
      final row = i ~/ _cols;
      final col = i % _cols;
      centers.add(Offset(
        col * cellWidth + cellWidth / 2,
        row * cellHeight + cellHeight / 2,
      ));
    }
    return centers;
  }

  int? _indexAt(Offset local, Size size) {
    final centers = _getDotCenters(size);
    final cellSize = size.width / _cols;
    for (int i = 0; i < centers.length; i++) {
      if ((centers[i] - local).distance <= (cellSize / 2) + _hitSlop) {
        return i;
      }
    }
    return null;
  }

  void _addIndex(int index) {
    if (_selected.contains(index)) return;
    setState(() => _selected.add(index));
  }

  void _endPattern() {
    if (widget.wrongAttempt) return;
    if (_selected.length >= widget.minLength) {
      widget.onPatternComplete(List<int>.from(_selected));
    } else if (_selected.isNotEmpty && widget.onPatternTooShort != null) {
      widget.onPatternTooShort!();
    }
    setState(() {
      _currentPosition = null;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final centers = _getDotCenters(size);
          return GestureDetector(
            onPanStart: (details) {
              final local = details.localPosition;
              final index = _indexAt(local, size);
              if (index != null) {
                _addIndex(index);
                setState(() => _currentPosition = centers[index]);
              }
            },
            onPanUpdate: (details) {
              final local = details.localPosition;
              final index = _indexAt(local, size);
              if (index != null) {
                _addIndex(index);
              }
              setState(() => _currentPosition = details.localPosition);
            },
            onPanEnd: (_) => _endPattern(),
            onPanCancel: () => _endPattern(),
            child: CustomPaint(
              size: size,
              painter: _PatternLockPainter(
                selected: widget.wrongAttempt ? <int>[] : _selected,
                currentPosition: _currentPosition,
                centers: centers,
                dotRadius: _dotRadius,
                wrong: widget.wrongAttempt,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PatternLockPainter extends CustomPainter {
  final List<int> selected;
  final Offset? currentPosition;
  final List<Offset> centers;
  final double dotRadius;
  final bool wrong;

  _PatternLockPainter({
    required this.selected,
    required this.currentPosition,
    required this.centers,
    required this.dotRadius,
    required this.wrong,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final lineColor = wrong ? AppTheme.warning : AppTheme.accent;
    final dotColor = wrong ? AppTheme.warning : AppTheme.accent;
    final dotFillColor = wrong ? AppTheme.warning.withOpacity(0.3) : AppTheme.accent.withOpacity(0.2);

    // Line from last dot to current finger position
    if (selected.isNotEmpty && currentPosition != null) {
      final lastCenter = centers[selected.last];
      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(lastCenter, currentPosition!, linePaint);
    }

    // Lines between selected dots
    for (int i = 0; i < selected.length - 1; i++) {
      final a = centers[selected[i]];
      final b = centers[selected[i + 1]];
      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, b, linePaint);
    }

    // Dots
    for (int i = 0; i < centers.length; i++) {
      final isSelected = selected.contains(i);
      final center = centers[i];
      final fillPaint = Paint()
        ..color = isSelected ? dotFillColor : AppTheme.surfaceVariant;
      final borderPaint = Paint()
        ..color = isSelected ? dotColor : AppTheme.divider
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, dotRadius, fillPaint);
      canvas.drawCircle(center, dotRadius, borderPaint);
      if (isSelected) {
        canvas.drawCircle(center, dotRadius * 0.4, Paint()..color = dotColor);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PatternLockPainter old) {
    return old.selected != selected ||
        old.currentPosition != currentPosition ||
        old.wrong != wrong;
  }
}
