import 'package:flutter/material.dart';
import '../../../app/theme.dart';

/// Albums management page
class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Albums'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: const Center(
        child: Text(
          'Albums Page',
          style: TextStyle(color: AppTheme.text),
        ),
      ),
    );
  }
}
