import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/panic_switch_service.dart';
import '../../../core/services/tamper_detection_service.dart';
import '../../../shared/widgets/secure_button.dart';
import '../../unlock/pages/pin_setup_page.dart';
import '../../unlock/pages/unlock_method_selection_page.dart';

/// Security settings page for PIN configuration
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});
  
  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  bool _isPanicSwitchEnabled = false;
  bool _isStrictModeEnabled = false;
  String? _unlockMethod;
  String? _unlockTriggerCode;
  
  @override
  void initState() {
    super.initState();
    _checkUnlockMethod();
    _loadUnlockTriggerCode();
    _loadPanicSwitchSettings();
    _loadTamperDetectionSettings();
  }

  Future<void> _loadUnlockTriggerCode() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final code = await authService.getUnlockTriggerCode();
    if (mounted) {
      setState(() {
        _unlockTriggerCode = code;
      });
    }
  }
  
  Future<void> _loadTamperDetectionSettings() async {
    final tamperDetection = Provider.of<TamperDetectionService>(context, listen: false);
    final enabled = await tamperDetection.isStrictModeEnabled();
    if (mounted) {
      setState(() {
        _isStrictModeEnabled = enabled;
      });
    }
  }
  
  Future<void> _toggleStrictMode(bool value) async {
    if (value) {
      // Show warning dialog before enabling strict mode
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Enable Strict Mode?'),
          content: const Text(
            'Strict mode will permanently wipe your vault if tampering is detected (debugger, root, or too many failed attempts).\n\n'
            'This action is IRREVERSIBLE. Your data cannot be recovered after a wipe.\n\n'
            'Are you sure you want to enable strict mode?',
            style: TextStyle(color: AppTheme.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.warning,
              ),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      
      if (confirmed != true) return;
    }
    
    final tamperDetection = Provider.of<TamperDetectionService>(context, listen: false);
    if (value) {
      await tamperDetection.enableStrictMode();
    } else {
      await tamperDetection.disableStrictMode();
    }
    
    if (mounted) {
      setState(() {
        _isStrictModeEnabled = value;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'Strict mode enabled. Vault will be wiped on tampering.'
                : 'Strict mode disabled.',
          ),
          backgroundColor: value ? AppTheme.warning : AppTheme.accent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
  
  Future<void> _loadPanicSwitchSettings() async {
    final panicSwitchService = Provider.of<PanicSwitchService>(context, listen: false);
    final enabled = await panicSwitchService.isEnabled();
    if (mounted) {
      setState(() {
        _isPanicSwitchEnabled = enabled;
      });
    }
  }
  
  Future<void> _togglePanicSwitch(bool value) async {
    final panicSwitchService = Provider.of<PanicSwitchService>(context, listen: false);
    
    if (value) {
      await panicSwitchService.enable();
    } else {
      await panicSwitchService.disable();
    }
    
    if (mounted) {
      setState(() {
        _isPanicSwitchEnabled = value;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value 
              ? 'Panic switch enabled. Turn phone face-down to exit app.'
              : 'Panic switch disabled.',
          ),
          backgroundColor: AppTheme.accent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _checkUnlockMethod() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final method = await authService.getUnlockMethod();
    if (mounted) {
      setState(() {
        _unlockMethod = method ?? 'pin';
      });
    }
  }
  
  Future<void> _changePIN() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Change PIN?'),
        content: const Text(
          'You will need to enter a new PIN. Your vault will be re-encrypted with the new PIN.',
          style: TextStyle(color: AppTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.accent,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    
    if (confirmed == true && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const PinSetupPage(isChangeMethod: true),
        ),
      ).then((_) {
        _checkUnlockMethod(); // Refresh method after change
      });
    }
  }

  Future<void> _changeUnlockTriggerCode() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _UnlockTriggerCodeDialog(currentCode: _unlockTriggerCode),
    );

    if (result != null && result.isNotEmpty) {
      final authService = Provider.of<AuthService>(context, listen: false);
      final success = await authService.setUnlockTriggerCode(result);

      if (mounted) {
        if (success) {
          await _loadUnlockTriggerCode();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unlock code updated'),
              backgroundColor: AppTheme.accent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid code. Code must contain only numbers and cannot start with 0.'),
              backgroundColor: AppTheme.warning,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('Security'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Security Overview
          _buildSection(
            title: 'Security Overview',
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          color: AppTheme.accent,
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Zero-Knowledge Architecture',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.text,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Your data is encrypted on-device. We never see your files.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.text.withOpacity(0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _SecurityPoint(
                      icon: Icons.lock_outline,
                      title: 'PIN Authentication',
                      description: '6-digit PIN protects your vault',
                    ),
                    const SizedBox(height: 12),
                    const SizedBox(height: 12),
                    _SecurityPoint(
                      icon: Icons.lock_outline,
                      title: 'AES-256-GCM Encryption',
                      description: 'Military-grade encryption for all files',
                    ),
                    const SizedBox(height: 12),
                    _SecurityPoint(
                      icon: Icons.vpn_key_outlined,
                      title: 'Per-File Encryption Keys',
                      description: 'Each file has its own unique encryption key',
                    ),
                    const SizedBox(height: 12),
                    _SecurityPoint(
                      icon: Icons.phone_android_outlined,
                      title: 'On-Device Only',
                      description: 'All encryption happens locally on your device',
                    ),
                    const SizedBox(height: 12),
                    _SecurityPoint(
                      icon: Icons.security,
                      title: 'Tamper Detection',
                      description: 'Detects debugger, root, and failed unlock attempts',
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Authentication Settings
          _buildSection(
            title: 'Authentication',
            children: [
              // Panic Switch
              SwitchListTile(
                secondary: const Icon(Icons.flip_camera_android, color: AppTheme.accent),
                title: const Text(
                  'Panic Switch',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  'Exit app when phone is face-down',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                value: _isPanicSwitchEnabled,
                onChanged: _togglePanicSwitch,
                activeColor: AppTheme.accent,
              ),
              
              const Divider(height: 1),
              
              // Change PIN
              ListTile(
                leading: const Icon(
                  Icons.lock_outline,
                  color: AppTheme.accent,
                ),
                title: const Text(
                  'Change PIN',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  'Update your 6-digit PIN',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: _changePIN,
              ),
              
              const Divider(height: 1),

              // Unlock code (stored for compatibility; main access is via PIN on unlock screen)
              ListTile(
                leading: const Icon(Icons.vpn_key, color: AppTheme.accent),
                title: Text(
                  'Unlock code',
                  style: const TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  _unlockTriggerCode != null ? 'Current: $_unlockTriggerCode' : 'Optional code (PIN is used on unlock screen)',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: AppTheme.text.withOpacity(0.4),
                ),
                onTap: _changeUnlockTriggerCode,
              ),

              const Divider(height: 1),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Tamper Detection
          _buildSection(
            title: 'Tamper Detection',
            children: [
              SwitchListTile(
                secondary: Icon(
                  _isStrictModeEnabled ? Icons.security : Icons.shield_outlined,
                  color: _isStrictModeEnabled ? AppTheme.warning : AppTheme.accent,
                ),
                title: Text(
                  'Strict Mode',
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  _isStrictModeEnabled
                      ? 'Vault will be permanently wiped on tampering'
                      : 'Standard mode: lockouts only, no wipe',
                  style: TextStyle(
                    color: AppTheme.text.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
                value: _isStrictModeEnabled,
                onChanged: _toggleStrictMode,
                activeColor: AppTheme.warning,
              ),
              if (_isStrictModeEnabled)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.warning.withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: AppTheme.warning,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Strict mode is enabled. Any tampering (debugger, root, or 5+ failed attempts) will permanently wipe your vault. This cannot be undone.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          
          const SizedBox(height: 24),
          
          // Security Tips
          _buildSection(
            title: 'Security Tips',
            children: [
              _SecurityTip(
                icon: Icons.lock_clock_outlined,
                title: 'Use a Strong PIN',
                description: 'Choose a PIN that\'s easy for you to remember but hard for others to guess.',
              ),
              const Divider(height: 1),
              _SecurityTip(
                icon: Icons.visibility_off_outlined,
                title: 'Keep Your PIN Private',
                description: 'Never share your PIN with anyone. If someone knows your PIN, they can access your vault.',
              ),
              const Divider(height: 1),
              _SecurityTip(
                icon: Icons.backup_outlined,
                title: 'Remember Your PIN',
                description: 'If you forget your PIN, your data cannot be recovered. We cannot reset it for you.',
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: AppTheme.text.withOpacity(0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Card(
          color: AppTheme.surface,
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }
}

class _SecurityPoint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  
  const _SecurityPoint({
    required this.icon,
    required this.title,
    required this.description,
  });
  
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.accent, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.text.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SecurityTip extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  
  const _SecurityTip({
    required this.icon,
    required this.title,
    required this.description,
  });
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.accent, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
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
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnlockTriggerCodeDialog extends StatefulWidget {
  final String? currentCode;

  const _UnlockTriggerCodeDialog({this.currentCode});

  @override
  State<_UnlockTriggerCodeDialog> createState() => _UnlockTriggerCodeDialogState();
}

class _UnlockTriggerCodeDialogState extends State<_UnlockTriggerCodeDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.currentCode != null) {
      _controller.text = widget.currentCode!;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _validateAndSubmit() {
    final code = _controller.text.trim();

    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Code cannot be empty';
      });
      return;
    }

    if (!RegExp(r'^\d+$').hasMatch(code)) {
      setState(() {
        _errorMessage = 'Code must contain only numbers';
      });
      return;
    }

    if (code.startsWith('0')) {
      setState(() {
        _errorMessage = 'Code cannot start with 0. Please enter a code that starts with 1-9.';
      });
      return;
    }

    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text(
        'Set unlock code',
        style: TextStyle(color: AppTheme.text),
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Optional code stored for vault access. Your PIN is used on the unlock screen to open your vault.',
              style: TextStyle(color: AppTheme.text),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                labelText: 'Trigger Code',
                labelStyle: TextStyle(color: AppTheme.text.withOpacity(0.7)),
                hintText: 'e.g., 123456',
                hintStyle: TextStyle(color: AppTheme.text.withOpacity(0.4)),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.text.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.accent),
                ),
                errorText: _errorMessage,
              ),
              autofocus: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _validateAndSubmit,
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.accent,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
