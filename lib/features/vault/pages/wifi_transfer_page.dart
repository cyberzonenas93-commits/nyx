import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../app/theme.dart';
import '../../../core/services/wifi_transfer_service.dart';

/// WiFi Transfer Page - Enables file transfer between app and computer
class WiFiTransferPage extends StatefulWidget {
  const WiFiTransferPage({super.key});

  @override
  State<WiFiTransferPage> createState() => _WiFiTransferPageState();
}

class _WiFiTransferPageState extends State<WiFiTransferPage> {
  StreamSubscription<TransferEvent>? _transferEventSubscription;

  @override
  void initState() {
    super.initState();
    _setupTransferListener();
  }

  @override
  void dispose() {
    _transferEventSubscription?.cancel();
    super.dispose();
  }

  void _setupTransferListener() {
    final transferService = Provider.of<WiFiTransferService>(context, listen: false);
    _transferEventSubscription = transferService.transferEvents.listen((event) {
      if (!mounted) return;
      
      final isUpload = event.type == TransferEventType.upload;
      final action = isUpload ? 'Received' : 'Sent';
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: event.success 
                      ? Colors.white.withOpacity(0.2) 
                      : Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  event.success
                      ? (isUpload ? Icons.file_download : Icons.file_upload)
                      : Icons.error_outline,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.success ? action : 'Error',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      event.success 
                          ? '${event.filename}\n${_formatBytes(event.sizeBytes)}'
                          : (event.error ?? 'Unknown error'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.9),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          backgroundColor: event.success ? AppTheme.accent : AppTheme.warning,
          duration: Duration(seconds: event.success ? 4 : 5),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final transferService = Provider.of<WiFiTransferService>(context);
    final urlToOpen = transferService.serverUrlWithToken ?? transferService.serverUrl;

    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('WiFi Transfer'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Card
            Card(
              color: AppTheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      transferService.isRunning
                          ? Icons.wifi
                          : Icons.wifi_off,
                      size: 48,
                      color: transferService.isRunning
                          ? AppTheme.accent
                          : AppTheme.text.withOpacity(0.5),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      transferService.isRunning
                          ? 'Server Running'
                          : 'Server Stopped',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (transferService.isRunning && urlToOpen != null)
                      Text(
                        transferService.serverUrl!,
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.accent,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      )
                    else if (!transferService.isRunning)
                      Text(
                        'Start the server to enable file transfer',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppTheme.text.withOpacity(0.7),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    if (transferService.isRunning && transferService.serverUrl != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Phone and computer must be on the same WiFi.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.text.withOpacity(0.6),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (!transferService.isUrlReachableFromComputer) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.warning.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'This device may not be on WiFi. Connect to WiFi and tap Stop then Start to get a reachable address.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.warning,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Control Button
            ElevatedButton.icon(
              onPressed: transferService.isRunning
                  ? () => _stopServer(transferService)
                  : () => _startServer(transferService),
              icon: Icon(
                transferService.isRunning ? Icons.stop : Icons.play_arrow,
              ),
              label: Text(
                transferService.isRunning ? 'Stop Server' : 'Start Server',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: transferService.isRunning
                    ? AppTheme.warning
                    : AppTheme.accent,
                foregroundColor: AppTheme.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),

            if (transferService.isRunning && urlToOpen != null) ...[
              const SizedBox(height: 30),

              // QR Code Card
              Card(
                color: AppTheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text(
                        'Scan QR Code to Open',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: QrImageView(
                          data: urlToOpen,
                          version: QrVersions.auto,
                          size: 200,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Or open in browser on your computer:',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppTheme.text.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'If the site doesn\'t load: same WiFi, and allow Local Network for Nyx in Settings > Privacy.',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.text.withOpacity(0.5),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Expanded(
                            child: SelectableText(
                              urlToOpen,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppTheme.accent,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 20),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: urlToOpen),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('URL copied to clipboard!'),
                                  duration: Duration(seconds: 2),
                                  backgroundColor: AppTheme.accent,
                                ),
                              );
                            },
                            tooltip: 'Copy URL',
                            color: AppTheme.accent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Instructions Card
              Card(
                color: AppTheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppTheme.accent,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Instructions',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.text,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildInstruction(
                        '1',
                        'Make sure your phone and computer are on the same WiFi network',
                      ),
                      const SizedBox(height: 12),
                      _buildInstruction(
                        '2',
                        'On your computer, open any web browser (Chrome, Safari, Firefox, Edge, etc.)',
                      ),
                      const SizedBox(height: 12),
                      _buildInstruction(
                        '3',
                        'Type the URL shown above into your browser\'s address bar and press Enter. Or scan the QR code with your computer\'s camera',
                      ),
                      const SizedBox(height: 12),
                      _buildInstruction(
                        '4',
                        'You\'ll see a web page where you can:\n• Drag & drop files to upload to your vault\n• Download files from your vault to your computer\n• Delete files from your vault',
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Statistics Card
              Card(
                color: AppTheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Transfer Statistics',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildStatRow(
                        'Files Uploaded',
                        transferService.uploadedFiles.toString(),
                      ),
                      const SizedBox(height: 8),
                      _buildStatRow(
                        'Files Downloaded',
                        transferService.downloadedFiles.toString(),
                      ),
                      const SizedBox(height: 8),
                      _buildStatRow(
                        'Uploaded Size',
                        _formatBytes(transferService.totalUploadedBytes),
                      ),
                      const SizedBox(height: 8),
                      _buildStatRow(
                        'Downloaded Size',
                        _formatBytes(transferService.totalDownloadedBytes),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInstruction(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: AppTheme.accent,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppTheme.text.withOpacity(0.9),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppTheme.text.withOpacity(0.7),
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: AppTheme.accent,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes == 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    final i = (bytes / k).floor().toString().length - 1;
    final sizeIndex = i.clamp(0, sizes.length - 1);
    return '${(bytes / (k * sizeIndex)).toStringAsFixed(2)} ${sizes[sizeIndex]}';
  }

  Future<void> _startServer(WiFiTransferService service) async {
    final success = await service.startServer();
    if (!success && mounted) {
      final error = service.lastStartError;
      final message = error != null && error.isNotEmpty
          ? 'Failed to start server: $error. Use same WiFi and, on iOS, allow Local Network when prompted.'
          : 'Failed to start server. Connect to WiFi and try again. On iOS, allow Local Network when prompted.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppTheme.warning,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'OK',
            textColor: AppTheme.primary,
            onPressed: () {},
          ),
        ),
      );
    }
  }

  Future<void> _stopServer(WiFiTransferService service) async {
    await service.stopServer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server stopped'),
          backgroundColor: AppTheme.accent,
        ),
      );
    }
  }
}
