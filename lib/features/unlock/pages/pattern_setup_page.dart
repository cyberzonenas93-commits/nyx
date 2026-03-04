import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/multi_vault_service.dart';
import '../../../core/services/encryption_service.dart';
import '../../vault/pages/vault_home_page.dart';
import '../widgets/pattern_lock_widget.dart';

/// Pattern unlock setup: draw pattern, then confirm.
/// Used for: primary setup, changing to pattern in settings, creating/resetting a secondary vault with pattern.
class PatternSetupPage extends StatefulWidget {
  final bool isChangeMethod;
  /// Create new secondary vault with this name and trigger code (pattern will be set).
  final String? vaultName;
  final String? vaultTriggerCode;
  /// Reset pattern for this existing secondary vault.
  final String? vaultIdToReset;

  const PatternSetupPage({
    super.key,
    this.isChangeMethod = false,
    this.vaultName,
    this.vaultTriggerCode,
    this.vaultIdToReset,
  });

  @override
  State<PatternSetupPage> createState() => _PatternSetupPageState();
}

class _PatternSetupPageState extends State<PatternSetupPage> {
  String? _firstPattern;
  bool _isConfirming = false;
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _onPatternComplete(List<int> indices) async {
    if (_isLoading) return;
    final patternString = patternToString(indices);

    if (!_isConfirming) {
      setState(() {
        _firstPattern = patternString;
        _isConfirming = true;
        _errorMessage = null;
      });
      return;
    }

    if (_firstPattern != patternString) {
      setState(() {
        _errorMessage = 'Patterns do not match. Try again.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);

      // Secondary vault: create new or reset pattern
      if ((widget.vaultName != null && widget.vaultTriggerCode != null) || widget.vaultIdToReset != null) {
        final encryptionService = EncryptionService();
        final salt = encryptionService.generateSalt();
        final hashedPattern = await encryptionService.hashPassword(patternString, salt);
        final saltHex = salt.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

        if (widget.vaultIdToReset != null) {
          await multiVaultService.updateSecondaryVaultPattern(
            widget.vaultIdToReset!,
            hashedPattern,
            saltHex,
          );
          if (!mounted) return;
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pattern updated successfully'),
              backgroundColor: AppTheme.accent,
            ),
          );
          Navigator.of(context).pop(true);
          return;
        }

        await multiVaultService.createSecondaryVault(
          name: widget.vaultName!,
          triggerCode: widget.vaultTriggerCode!,
          patternHash: hashedPattern,
          patternSalt: saltHex,
        );
        if (!mounted) return;
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Vault "${widget.vaultName}" created successfully!'),
            backgroundColor: AppTheme.accent,
          ),
        );
        Navigator.of(context).pop(true);
        return;
      }

      // Primary vault
      final success = await authService.setupPattern(patternString);

      if (!mounted) return;
      if (success) {
        if (widget.isChangeMethod) {
          Navigator.of(context).pop();
          return;
        }
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const VaultHomePage(vaultId: null),
          ),
          (route) => false,
        );
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to set up pattern. Try again.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Something went wrong. Try again.';
        });
      }
    }
  }

  void _onPatternTooShort() {
    setState(() {
      _errorMessage = 'Use at least 4 dots.';
    });
  }

  bool get _isSecondaryVault =>
      (widget.vaultName != null && widget.vaultTriggerCode != null) || widget.vaultIdToReset != null;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.isChangeMethod || _isSecondaryVault,
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        appBar: AppBar(
          title: const Text('Set pattern'),
          backgroundColor: AppTheme.surface,
          elevation: 0,
          leading: (widget.isChangeMethod || _isSecondaryVault)
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                )
              : null,
          automaticallyImplyLeading: widget.isChangeMethod || _isSecondaryVault,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.gesture_outlined,
                    size: 56,
                    color: AppTheme.accent,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _isConfirming ? 'Draw pattern again to confirm' : 'Draw your unlock pattern',
                    style: const TextStyle(
                      color: AppTheme.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isConfirming
                        ? 'Repeat the same pattern'
                        : 'Connect at least 4 dots',
                    style: TextStyle(
                      color: AppTheme.text.withOpacity(0.7),
                      fontSize: 16,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  PatternLockWidget(
                    minLength: kPatternMinLength,
                    onPatternComplete: _onPatternComplete,
                    onPatternTooShort: _onPatternTooShort,
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: AppTheme.warning,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_isLoading) ...[
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(color: AppTheme.accent),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
