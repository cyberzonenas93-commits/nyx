import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/tamper_detection_service.dart';
import '../../../core/services/multi_vault_service.dart';
import '../../../core/models/app_state.dart';
import '../../vault/pages/vault_home_page.dart';
import '../widgets/pattern_lock_widget.dart';

// Intent classes for keyboard shortcuts
class _NumericIntent extends Intent {
  final int value;
  const _NumericIntent(this.value);
}

class _BackspaceIntent extends Intent {
  const _BackspaceIntent();
}

/// Unlock screen with PIN pad
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});
  
  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final ValueNotifier<String> _pinNotifier = ValueNotifier<String>('');
  final ValueNotifier<String?> _errorMessageNotifier = ValueNotifier<String?>(null);
  String _pin = '';
  bool _isLoading = false;
  String? _unlockMethod;
  bool _patternWrongAttempt = false;
  
  @override
  void initState() {
    super.initState();
    _checkUnlockMethod();
  }
  
  @override
  void dispose() {
    _pinNotifier.dispose();
    _errorMessageNotifier.dispose();
    super.dispose();
  }
  
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_isLoading) return KeyEventResult.ignored;
    
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      
      // Handle numeric keys (0-9)
      if (key.keyLabel.length == 1 && key.keyLabel.codeUnitAt(0) >= 48 && key.keyLabel.codeUnitAt(0) <= 57) {
        final number = key.keyLabel;
        _onNumberPressed(number);
        return KeyEventResult.handled;
      }
      // Handle backspace/delete
      else if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
        _onBackspace();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
  
  void _onNumberPressed(String number) {
    if (_pin.length >= 6) return;
    
    if (_pin.isEmpty && number == '0') {
      _errorMessageNotifier.value = 'PIN cannot start with 0. Please enter a number from 1-9 first.';
      return;
    }
    
    _pin += number;
    _pinNotifier.value = _pin;
    if (_errorMessageNotifier.value != null) _errorMessageNotifier.value = null;
    
    if (_pin.length == 6) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _verifyPIN();
      });
    }
  }
  
  void _onBackspace() {
    if (_pin.isEmpty) return;
    _pin = _pin.substring(0, _pin.length - 1);
    _pinNotifier.value = _pin;
    if (_errorMessageNotifier.value != null) _errorMessageNotifier.value = null;
  }
  
  Future<void> _setupVault(String pin) async {
    if (mounted) {
      setState(() => _isLoading = true);
      _errorMessageNotifier.value = null;
    }
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final success = await authService.setupPIN(pin);
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (!success) {
        _pin = '';
        _pinNotifier.value = _pin;
        _errorMessageNotifier.value = 'Failed to set up vault';
      }
    } catch (e) {
      debugPrint('[UnlockPage] Error setting up vault: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        _pin = '';
        _pinNotifier.value = _pin;
        _errorMessageNotifier.value = 'Failed to set up vault: ${e.toString()}';
      }
    }
  }
  
  void _navigateToVault(String? vaultId) {
    setState(() => _isLoading = false);
    _errorMessageNotifier.value = null;
    _pin = '';
    _pinNotifier.value = _pin;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) => VaultHomePage(vaultId: vaultId),
      ),
      (route) => false,
    );
  }

  Future<void> _verifyPIN() async {
    if (mounted) {
      setState(() => _isLoading = true);
      _errorMessageNotifier.value = null;
    }
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final tamperDetection = Provider.of<TamperDetectionService>(context, listen: false);
      final tamperResult = await tamperDetection.checkTampering();
      if (tamperResult.isTampered && tamperResult.shouldWipe) {
        if (mounted) {
          setState(() => _isLoading = false);
          _errorMessageNotifier.value = 'Security violation detected. Vault has been wiped.';
        }
        return;
      }
      final result = await authService.verifyPIN(_pin);
      if (!mounted) return;
      if (result == AuthResult.notInitialized) {
        await _setupVault(_pin);
        return;
      }
      if (result == AuthResult.unlocked) {
        await tamperDetection.resetFailedAttempts();
        if (mounted) _navigateToVault(authService.currentVaultId);
        return;
      }
      if (result == AuthResult.failed) {
        final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
        final secondaryVaults = multiVaultService.vaults.where((v) => !v.isPrimary).toList();
        for (final vault in secondaryVaults) {
          final ok = await authService.verifySecondaryVaultPIN(vault.id, _pin);
          if (!mounted) return;
          if (ok) {
            await tamperDetection.resetFailedAttempts();
            if (mounted) _navigateToVault(vault.id);
            return;
          }
        }
        await tamperDetection.recordFailedAttempt();
      }
      if (mounted) {
        setState(() => _isLoading = false);
        _pin = '';
        _pinNotifier.value = _pin;
        _errorMessageNotifier.value = 'Incorrect PIN';
      }
    } catch (e) {
      debugPrint('[UnlockPage] Error verifying PIN: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        _pin = '';
        _pinNotifier.value = _pin;
        _errorMessageNotifier.value = 'Error verifying PIN';
      }
    }
  }

  Future<void> _verifyPattern(String patternString) async {
    if (mounted) {
      setState(() => _isLoading = true);
      _errorMessageNotifier.value = null;
    }
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final tamperDetection = Provider.of<TamperDetectionService>(context, listen: false);
      final tamperResult = await tamperDetection.checkTampering();
      if (tamperResult.isTampered && tamperResult.shouldWipe) {
        if (mounted) {
          setState(() => _isLoading = false);
          _errorMessageNotifier.value = 'Security violation detected. Vault has been wiped.';
        }
        return;
      }
      final result = await authService.verifyPattern(patternString);
      if (!mounted) return;
      if (result == AuthResult.unlocked) {
        await tamperDetection.resetFailedAttempts();
        if (mounted) _navigateToVault(authService.currentVaultId);
        return;
      }
      // Primary didn't match – try each secondary vault's pattern
      if (result == AuthResult.failed) {
        final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
        final secondaryVaults = multiVaultService.vaults.where((v) => !v.isPrimary).toList();
        for (final vault in secondaryVaults) {
          final ok = await authService.verifySecondaryVaultPattern(vault.id, patternString);
          if (!mounted) return;
          if (ok) {
            await tamperDetection.resetFailedAttempts();
            if (mounted) _navigateToVault(vault.id);
            return;
          }
        }
        await tamperDetection.recordFailedAttempt();
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
          _patternWrongAttempt = true;
        });
        _errorMessageNotifier.value = 'Wrong pattern';
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) setState(() => _patternWrongAttempt = false);
        });
      }
    } catch (e) {
      debugPrint('[UnlockPage] Error verifying pattern: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        _errorMessageNotifier.value = 'Error verifying pattern';
      }
    }
  }
  
  
  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.digit0): _NumericIntent(0),
        LogicalKeySet(LogicalKeyboardKey.digit1): _NumericIntent(1),
        LogicalKeySet(LogicalKeyboardKey.digit2): _NumericIntent(2),
        LogicalKeySet(LogicalKeyboardKey.digit3): _NumericIntent(3),
        LogicalKeySet(LogicalKeyboardKey.digit4): _NumericIntent(4),
        LogicalKeySet(LogicalKeyboardKey.digit5): _NumericIntent(5),
        LogicalKeySet(LogicalKeyboardKey.digit6): _NumericIntent(6),
        LogicalKeySet(LogicalKeyboardKey.digit7): _NumericIntent(7),
        LogicalKeySet(LogicalKeyboardKey.digit8): _NumericIntent(8),
        LogicalKeySet(LogicalKeyboardKey.digit9): _NumericIntent(9),
        LogicalKeySet(LogicalKeyboardKey.backspace): _BackspaceIntent(),
        LogicalKeySet(LogicalKeyboardKey.delete): _BackspaceIntent(),
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Actions(
          actions: <Type, Action<Intent>>{
            _NumericIntent: CallbackAction<_NumericIntent>(
              onInvoke: (intent) {
                if (!_isLoading && _pinNotifier.value.length < 6) {
                  _onNumberPressed(intent.value.toString());
                }
                return null;
              },
            ),
            _BackspaceIntent: CallbackAction<_BackspaceIntent>(
              onInvoke: (_) {
                if (!_isLoading) {
                  _onBackspace();
                }
                return null;
              },
            ),
          },
          child: Scaffold(
        backgroundColor: AppTheme.primary,
        body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 700;
            final scale = isCompact ? 0.85 : 1.0;
            final padding = isCompact ? 12.0 : 32.0;
            final spacing = isCompact ? 24.0 : 48.0;
            final usePattern = _unlockMethod == 'pattern';
            return Padding(
              padding: EdgeInsets.all(padding),
              child: Center(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight - padding * 2),
                    child: Transform.scale(
                      scale: scale,
                      alignment: Alignment.center,
                      child: usePattern ? _buildPatternUnlock() : _buildPINUnlockContent(isCompact, spacing),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
          ),
        ),
      ),
    );
  }

  Widget _buildPatternUnlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Draw your pattern',
          style: TextStyle(
            color: AppTheme.text,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Draw your pattern to open your vault',
          style: TextStyle(
            color: AppTheme.text.withOpacity(0.8),
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        PatternLockWidget(
          minLength: kPatternMinLength,
          wrongAttempt: _patternWrongAttempt,
          onPatternComplete: (indices) {
            final patternString = patternToString(indices);
            _verifyPattern(patternString);
          },
          onPatternTooShort: () {
            _errorMessageNotifier.value = 'Use at least 4 dots';
          },
        ),
        ValueListenableBuilder<String?>(
          valueListenable: _errorMessageNotifier,
          builder: (context, errorMessage, child) {
            if (errorMessage == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                errorMessage,
                style: const TextStyle(color: AppTheme.warning, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            );
          },
        ),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: CircularProgressIndicator(color: AppTheme.accent),
          ),
      ],
    );
  }

  Widget _buildPINUnlockContent(bool isCompact, double spacing) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Enter your PIN',
          style: TextStyle(
            color: AppTheme.text,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter the 6-digit PIN to open your vault',
          style: TextStyle(
            color: AppTheme.text.withOpacity(0.8),
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: isCompact ? 16.0 : 32.0),
        Container(
          padding: EdgeInsets.all(isCompact ? 16.0 : 24),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.surface,
            boxShadow: [
              BoxShadow(
                color: AppTheme.accent.withOpacity(0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            Icons.lock_outline,
            size: isCompact ? 40.0 : 48,
            color: AppTheme.accent,
          ),
        ),
        SizedBox(height: isCompact ? 16.0 : 32.0),
        RepaintBoundary(
          child: ValueListenableBuilder<String>(
            valueListenable: _pinNotifier,
            builder: (context, pin, child) {
              return _PINDotsWidget(pinLength: pin.length);
            },
          ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: _errorMessageNotifier,
          builder: (context, errorMessage, child) {
            if (errorMessage == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                errorMessage,
                style: const TextStyle(
                  color: AppTheme.warning,
                  fontSize: 14,
                ),
              ),
            );
          },
        ),
        SizedBox(height: spacing),
        _buildPINUnlock(),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: CircularProgressIndicator(
              color: AppTheme.accent,
            ),
          ),
      ],
    );
  }
  
  Widget _buildPINUnlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            _NumberButton('1', onPressed: () => _onNumberPressed('1')),
            _NumberButton('2', onPressed: () => _onNumberPressed('2')),
            _NumberButton('3', onPressed: () => _onNumberPressed('3')),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _NumberButton('4', onPressed: () => _onNumberPressed('4')),
            _NumberButton('5', onPressed: () => _onNumberPressed('5')),
            _NumberButton('6', onPressed: () => _onNumberPressed('6')),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _NumberButton('7', onPressed: () => _onNumberPressed('7')),
            _NumberButton('8', onPressed: () => _onNumberPressed('8')),
            _NumberButton('9', onPressed: () => _onNumberPressed('9')),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: SizedBox()),
            _NumberButton('0', onPressed: () => _onNumberPressed('0')),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _pinNotifier,
                builder: (context, pin, child) {
                  return IconButton(
                    onPressed: pin.isNotEmpty ? _onBackspace : null,
                    icon: const Icon(Icons.backspace_outlined),
                    color: AppTheme.text,
                    iconSize: 28,
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
  
}

class _NumberButton extends StatelessWidget {
  final String number;
  final VoidCallback? onPressed;
  
  const _NumberButton(this.number, {this.onPressed});
  
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.surface,
            foregroundColor: AppTheme.text,
            padding: const EdgeInsets.symmetric(vertical: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
          ),
          child: Text(
            number,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// Extracted PIN dots widget for better performance - only rebuilds when PIN length changes
class _PINDotsWidget extends StatelessWidget {
  final int pinLength;
  
  const _PINDotsWidget({required this.pinLength});
  
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        final isFilled = index < pinLength;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled ? AppTheme.accent : AppTheme.surfaceVariant,
            border: Border.all(
              color: isFilled ? AppTheme.accent : AppTheme.divider,
              width: 2,
            ),
          ),
        );
      }),
    );
  }
}
