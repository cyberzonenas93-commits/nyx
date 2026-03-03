import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../app/theme.dart';
import '../../../core/services/wifi_transfer_service.dart';

/// WiFi Transfer: start a local server so a computer on the same WiFi
/// can open the URL to upload/download vault files.
class WiFiTransferPage extends StatefulWidget {
  const WiFiTransferPage({super.key});

  @override
  State<WiFiTransferPage> createState() => _WiFiTransferPageState();
}

class _WiFiTransferPageState extends State<WiFiTransferPage> {
  bool? _isPhysicalDevice;

  @override
  void initState() {
    super.initState();
    _loadIsPhysicalDevice();
  }

  Future<void> _loadIsPhysicalDevice() async {
    final deviceInfo = DeviceInfoPlugin();
    bool? physical;
    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      physical = android.isPhysicalDevice;
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      physical = ios.isPhysicalDevice;
    }
    if (mounted) setState(() => _isPhysicalDevice = physical);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('WiFi Transfer'),
        backgroundColor: AppTheme.surface,
      ),
      body: SafeArea(
        child: Consumer<WiFiTransferService>(
          builder: (context, service, _) {
            return Column(
              children: [
                if (service.isReceiving)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    color: AppTheme.accent.withValues(alpha: 0.2),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Receiving files…',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (service.showUploadComplete && !service.isReceiving)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    color: AppTheme.accent.withValues(alpha: 0.15),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: AppTheme.accent, size: 24),
                        const SizedBox(width: 12),
                        Text(
                          'Upload complete',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      const SizedBox(height: 16),
                      Icon(
                  service.isRunning ? Icons.wifi : Icons.wifi_off,
                  size: 64,
                  color: service.isRunning ? AppTheme.accent : AppTheme.text.withOpacity(0.4),
                ),
                const SizedBox(height: 24),
                Text(
                  service.isRunning ? 'Server running' : 'Server stopped',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Use the same WiFi on your phone and computer. Open the URL below in your computer\'s browser to upload or download files.',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.text.withOpacity(0.7),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (service.isRunning && service.serverUrl != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                    ),
                    child: SelectableText(
                      service.serverUrl!,
                      style: const TextStyle(
                        fontSize: 16,
                        color: AppTheme.accent,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: service.serverUrl ?? ''));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('URL copied')),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy URL'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accent,
                          foregroundColor: AppTheme.primary,
                        ),
                      ),
                    ],
                  ),
                  // Only hide on real devices: show when 10.0.2.x and not known to be physical
                  if (service.isLikelyEmulator && _isPhysicalDevice != true) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(AppTheme.radius),
                        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Android emulator',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.warning,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'On your computer, run in a terminal:',
                            style: TextStyle(fontSize: 12, color: AppTheme.text),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            'adb reverse tcp:${service.port} tcp:${service.port}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: AppTheme.accent,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Then open in your browser:',
                            style: TextStyle(fontSize: 12, color: AppTheme.text),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            'http://127.0.0.1:${service.port}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: AppTheme.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (service.isDiscoverableOnNetwork) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Discoverable as "Nyx" on the network. Open Nyx.local in a browser or look in Network/Devices.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.accent.withValues(alpha: 0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (service.isReachableFromNetwork) ...[
                    const SizedBox(height: 28),
                    const Text(
                      'Or scan to open on computer',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.text,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: QrImageView(
                          data: service.serverUrl ?? '',
                          version: QrVersions.auto,
                          size: 180,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Text(
                      'Connect to WiFi and restart the server to get a reachable address.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.warning.withOpacity(0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 32),
                ],
                FilledButton.icon(
                  onPressed: () async {
                    if (service.isRunning) {
                      await service.stopServer();
                    } else {
                      final ok = await service.startServer();
                      if (context.mounted && !ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not start server. Check WiFi and try again.'),
                          ),
                        );
                      }
                    }
                  },
                  icon: Icon(service.isRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(service.isRunning ? 'Stop server' : 'Start server'),
                  style: FilledButton.styleFrom(
                    backgroundColor: service.isRunning ? AppTheme.warning : AppTheme.accent,
                    foregroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    minimumSize: const Size(double.infinity, 48),
                  ),
                ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

