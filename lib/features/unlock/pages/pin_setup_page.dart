import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/multi_vault_service.dart';
import '../../../core/services/encryption_service.dart';
import '../../../shared/widgets/secure_button.dart';
import 'unlock_page.dart';

/// PIN setup screen for first-time users with detailed guide
/// Also serves as method selection (PIN vs Pattern)
class PinSetupPage extends StatefulWidget {
  final bool isChangeMethod; // If true, allow changing unlock method
  final String? vaultName; // For secondary vault creation
  final String? vaultTriggerCode; // For secondary vault creation
  final bool isSecondaryVault; // If true, creating a secondary vault
  final bool isResettingPIN; // True if resetting an existing secondary vault PIN
  final String? vaultIdToReset; // The ID of the secondary vault whose PIN is being reset
  
  const PinSetupPage({
    super.key,
    this.isChangeMethod = false,
    this.vaultName,
    this.vaultTriggerCode,
    this.isSecondaryVault = false,
    this.isResettingPIN = false,
    this.vaultIdToReset,
  });
  
  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  String _pin = '';
  String _confirmPin = '';
  bool _isConfirming = false;
  bool _isLoading = false;
  String? _errorMessage;
  final FocusNode _keyboardFocusNode = FocusNode();
  
  @override
  void initState() {
    super.initState();
    // Request focus for keyboard input
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardFocusNode.requestFocus();
    });
  }
  
  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
  }
  
  void _handleKeyEvent(KeyEvent event) {
    if (_isLoading) return;
    
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      
      // Handle numeric keys (0-9)
      if (key.keyLabel.length == 1 && key.keyLabel.codeUnitAt(0) >= 48 && key.keyLabel.codeUnitAt(0) <= 57) {
        final number = key.keyLabel;
        _onNumberPressed(number);
      }
      // Handle backspace/delete
      else if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
        _onBackspace();
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.isChangeMethod, // Allow back navigation only if changing method
      onPopInvoked: (didPop) async {
        if (didPop || widget.isChangeMethod) return;
        // During onboarding, prevent going back - user must complete PIN setup
        // Show a dialog to confirm if they want to exit
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppTheme.surface,
            title: const Text(
              'Exit Setup?',
              style: TextStyle(color: AppTheme.text),
            ),
            content: Text(
              'You need to complete PIN setup to use the app. Are you sure you want to exit?',
              style: TextStyle(color: AppTheme.text.withOpacity(0.7)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel', style: TextStyle(color: AppTheme.text)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Exit', style: TextStyle(color: AppTheme.warning)),
              ),
            ],
          ),
        );
        
        if (shouldExit == true && mounted) {
          // Go back to unlock method selection
          Navigator.of(context).pop();
        }
      },
      child: KeyboardListener(
        focusNode: _keyboardFocusNode,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: Text(
          widget.isResettingPIN 
              ? 'Reset PIN' 
              : widget.isSecondaryVault 
                  ? 'Set Up Secondary Vault PIN'
                  : 'Set Up Your PIN',
        ),
        backgroundColor: AppTheme.surface,
        elevation: 0,
          leading: widget.isChangeMethod
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  tooltip: 'Back',
                )
              : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Scrollable top section
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Icon and title
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.surface,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accent.withValues(alpha: 0.3),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.lock_outline,
                          size: 48,
                          color: AppTheme.accent,
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // Instruction text
                    Text(
                      _isConfirming
                          ? 'Confirm Your PIN'
                          : widget.isResettingPIN
                              ? 'Enter New 6-Digit PIN'
                          : 'Create a 6-Digit PIN',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    
                    const SizedBox(height: 24),
                    
                    // PIN dots
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(6, (index) {
                        final isFilled = index < (_isConfirming ? _confirmPin : _pin).length;
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
                    ),
                    
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.warning.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                          border: Border.all(color: AppTheme.warning.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: AppTheme.warning, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: AppTheme.warning,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    
                    if (_isLoading)
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: CircularProgressIndicator(
                          color: AppTheme.accent,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            
            // Keypad - always visible at bottom
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                        child: IconButton(
                          onPressed: _onBackspace,
                          icon: const Icon(Icons.backspace_outlined),
                          color: AppTheme.text,
                          iconSize: 28,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
  
  void _onNumberPressed(String number) {
    if (_isLoading) return;
    
    setState(() {
      _errorMessage = null;
      
      if (_isConfirming) {
        if (_confirmPin.length < 6) {
          // Prevent 0 as first digit in confirmation
          if (_confirmPin.isEmpty && number == '0') {
            _errorMessage = 'PIN cannot start with 0. Please enter a number from 1-9 first.';
            return;
          }
          _confirmPin += number;
          
          if (_confirmPin.length == 6) {
            _completeSetup();
          }
        }
      } else {
        if (_pin.length < 6) {
          // Prevent 0 as first digit in PIN
          if (_pin.isEmpty && number == '0') {
            _errorMessage = 'PIN cannot start with 0. Please enter a number from 1-9 first.';
            return;
          }
          _pin += number;
          
          if (_pin.length == 6) {
            // Move to confirmation after a brief pause
            Future.delayed(const Duration(milliseconds: 300), () {
              if (mounted) {
                setState(() {
                  _isConfirming = true;
                });
              }
            });
          }
        }
      }
    });
    
  }
  
  void _onBackspace() {
    if (_isLoading) return;
    
    setState(() {
      _errorMessage = null;
      
      if (_isConfirming) {
        if (_confirmPin.isNotEmpty) {
          _confirmPin = _confirmPin.substring(0, _confirmPin.length - 1);
        }
      } else {
        if (_pin.isNotEmpty) {
          _pin = _pin.substring(0, _pin.length - 1);
        }
      }
    });
    
  }
  
  Future<void> _completeSetup() async {
    // Validate PIN doesn't start with 0
    if (_pin.startsWith('0')) {
      setState(() {
        _errorMessage = 'PIN cannot start with 0. Please enter a PIN starting with 1-9.';
        _pin = '';
        _confirmPin = '';
        _isConfirming = false;
      });
      return;
    }
    
    if (_pin != _confirmPin) {
      setState(() {
        _errorMessage = 'PINs do not match. Please try again.';
        _pin = '';
        _confirmPin = '';
        _isConfirming = false;
      });
      return;
    }
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    
    try {
      debugPrint('[PinSetupPage] Starting PIN setup...');
      final authService = Provider.of<AuthService>(context, listen: false);
      
        // Handle secondary vault creation or PIN reset
        if (widget.isSecondaryVault && widget.vaultName != null && widget.vaultTriggerCode != null) {
          final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
          final encryptionService = EncryptionService();
          final secureStorage = const FlutterSecureStorage();
          
          // Create PIN hash and salt for secondary vault (same as primary vault)
          final salt = encryptionService.generateSalt();
          final pinHash = await encryptionService.hashPassword(_pin, salt);
          
          // Convert salt bytes to hex string for storage (same as primary vault)
          final saltHex = salt.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
          
          debugPrint('[PinSetupPage] Secondary vault PIN hash created, length: ${pinHash.length}');
          debugPrint('[PinSetupPage] Secondary vault salt hex: $saltHex');
          debugPrint('[PinSetupPage] Is resetting PIN: ${widget.isResettingPIN}');
          
          try {
            if (widget.isResettingPIN && widget.vaultIdToReset != null) {
              // Update PIN hash and salt in secure storage for the specified vault
              await secureStorage.write(key: 'pin_hash_${widget.vaultIdToReset}', value: pinHash);
              await secureStorage.write(key: 'pin_salt_${widget.vaultIdToReset}', value: saltHex);
              
              debugPrint('[PinSetupPage] Secondary vault PIN reset for vault: ${widget.vaultIdToReset}');
              
              if (mounted) {
                setState(() {
                  _isLoading = false;
                });
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('PIN reset successfully for "${widget.vaultName}"!'),
                    backgroundColor: AppTheme.accent,
                  ),
                );
                
                Navigator.of(context).pop(true); // Return success
              }
            } else {
              // Create new secondary vault
              await multiVaultService.createSecondaryVault(
                name: widget.vaultName!,
                triggerCode: widget.vaultTriggerCode!,
                pinHash: pinHash,
                pinSalt: saltHex,
                secureStorage: secureStorage,
              );
              
              if (mounted) {
                setState(() {
                  _isLoading = false;
                });
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Vault "${widget.vaultName}" created successfully!'),
                    backgroundColor: AppTheme.accent,
                  ),
                );
                
                Navigator.of(context).pop(true); // Return success
              }
            }
            return;
          } catch (e) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _errorMessage = widget.isResettingPIN 
                    ? 'Error resetting PIN: $e'
                    : 'Error creating vault: $e';
              });
            }
            return;
          }
        }
      
      // Primary vault setup
      final success = await authService.setupPIN(_pin);
      
      // Initialize primary vault in multi-vault service
      if (success) {
        final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);
        final triggerCode = await authService.getUnlockTriggerCode() ?? _pin;
        try {
          await multiVaultService.initializePrimaryVault(triggerCode);
        } catch (e) {
          debugPrint('[PinSetupPage] Error initializing primary vault: $e');
          // Continue anyway - vault might already exist
        }
      }
      
      debugPrint('[PinSetupPage] PIN setup result: $success');
      
      if (!mounted) return;
      
      if (success) {
        debugPrint('[PinSetupPage] PIN setup successful');
        // Setup successful - AuthService has updated app state to locked (unlock screen)
        // Clear loading state first
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        
        // Show tutorial dialog explaining unlock code vs vault code
        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              backgroundColor: AppTheme.surface,
              title: const Text(
                'PIN set successfully',
                style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'What happens next:',
                    style: TextStyle(color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '1. Tap "Continue" below.\n'
                    '2. On the next screen, enter your 6-digit PIN.\n'
                    '3. Your vault will open and you can start adding files.',
                    style: TextStyle(color: AppTheme.text, fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Remember your PIN — you\'ll need it every time you open Nyx.',
                    style: TextStyle(color: AppTheme.text.withOpacity(0.85), fontSize: 14, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(); // Close dialog
                    if (mounted) {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (context) => const UnlockPage()),
                        (route) => false,
                      );
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                  ),
                  child: const Text('Continue'),
                ),
              ],
            ),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Failed to set up PIN. Please try again.';
            _pin = '';
            _confirmPin = '';
            _isConfirming = false;
          });
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[PinSetupPage] Exception during PIN setup: $e');
      debugPrint('[PinSetupPage] Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to set up PIN: $e. Please check console for details.';
          _pin = '';
          _confirmPin = '';
          _isConfirming = false;
        });
      }
    }
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
