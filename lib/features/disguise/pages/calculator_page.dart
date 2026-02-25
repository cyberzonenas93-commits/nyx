import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/subscription_service.dart';
import '../../../core/services/multi_vault_service.dart';
import '../../../core/services/vault_service.dart';
import '../../../core/models/vault_metadata.dart';
import '../../../shared/widgets/pin_verification_dialog.dart';
import '../../vault/pages/vault_home_page.dart';

/// Advanced calculator interface - no indication of vault
class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  // Use ValueNotifier for display to minimize rebuilds
  final ValueNotifier<String> _displayNotifier = ValueNotifier<String>('0');
  final ValueNotifier<String> _expressionNotifier = ValueNotifier<String>(''); // shows pressed operators/operands

  String _display = '0'; // Keep for calculations
  String _operation = '';
  double _firstNumber = 0;
  bool _shouldReset = false;
  bool _showScientific = false;

  // Repeat "=" support (e.g. 2 + 2 = = -> 6)
  String _lastOperation = '';
  double? _lastSecondNumber;

  // Track consecutive "=" presses for PIN unlock
  DateTime? _lastEqualPress;
  static const _equalPressTimeout = Duration(seconds: 2);
  String? _unlockTriggerCode;
  List<VaultMetadata> _secondaryVaults = []; // All secondary vaults

  // Track God mode activation: "17031995" + division sign 3 times
  static const _godModeCode = '17031995';
  int _divisionPressCount = 0;
  DateTime? _lastDivisionPress;
  static const _divisionPressTimeout = Duration(seconds: 3);

  final FocusNode _keyboardFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadUnlockTriggerCodes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardFocusNode.requestFocus();
    });
  }

  Future<void> _loadUnlockTriggerCodes() async {
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      final multiVaultService = Provider.of<MultiVaultService>(context, listen: false);

      final code = await authService.getUnlockTriggerCode();
      final secondaryVaults = multiVaultService.vaults.where((v) => !v.isPrimary).toList();

      // These values are not used for UI; avoid setState to keep input smooth.
      _unlockTriggerCode = code;
      _secondaryVaults = secondaryVaults;
      assert(() {
        debugPrint(
          '[CalculatorPage] Loaded trigger codes - Primary: $_unlockTriggerCode, Secondary: ${secondaryVaults.length}',
        );
        return true;
      }());
    } catch (e) {
      debugPrint('[CalculatorPage] Error loading trigger codes: $e');
    }
  }

  @override
  void dispose() {
    _displayNotifier.dispose();
    _expressionNotifier.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _updateExpressionLine({String? override}) {
    if (override != null) {
      _expressionNotifier.value = override;
      return;
    }

    if (_operation.isEmpty) {
      // No pending operation; keep whatever was last shown (e.g. "80 + 80 =")
      return;
    }

    final a = _formatNumber(_firstNumber);
    if (_shouldReset) {
      _expressionNotifier.value = '$a $_operation';
    } else {
      _expressionNotifier.value = '$a $_operation $_display';
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = event.logicalKey;
    final label = key.keyLabel;

    // Numeric keys (0-9)
    if (label.length == 1 && label.codeUnitAt(0) >= 48 && label.codeUnitAt(0) <= 57) {
      _onNumberPressed(label);
      return;
    }

    // Operators
    if (label == '+' || key == LogicalKeyboardKey.numpadAdd) {
      _onOperationPressed('+');
      return;
    }
    if (label == '-' || key == LogicalKeyboardKey.numpadSubtract) {
      _onOperationPressed('-');
      return;
    }
    if (label == '*' || key == LogicalKeyboardKey.numpadMultiply) {
      _onOperationPressed('×');
      return;
    }
    if (label == '/' || key == LogicalKeyboardKey.numpadDivide) {
      _onOperationPressed('÷');
      return;
    }
    if (label == '%' || key == LogicalKeyboardKey.percent) {
      _onPercentPressed();
      return;
    }

    // Equals/Enter
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || label == '=') {
      _calculate();
      return;
    }

    // Clear/Escape
    if (key == LogicalKeyboardKey.escape) {
      _clear();
      return;
    }

    // Backspace
    if (key == LogicalKeyboardKey.backspace) {
      _deleteLastDigit();
      return;
    }

    // Decimal point
    if (label == '.' || key == LogicalKeyboardKey.numpadDecimal) {
      _onDecimalPressed();
    }
  }

  void _setDisplay(String value) {
    _display = value;
    _displayNotifier.value = _display;
    _updateExpressionLine();
  }

  void _onNumberPressed(String number) {
    _lastEqualPress = null;
    final wasReset = _shouldReset;
    if (_shouldReset) {
      _display = number;
      _shouldReset = false;
    } else {
      // iOS-style leading zeros
      _display = _display == '0' ? number : _display + number;
    }
    _displayNotifier.value = _display;

    // If the last thing we showed was a completed statement ("... =") and the user starts typing
    // a new number, clear the feedback line.
    if (wasReset && _operation.isEmpty && _expressionNotifier.value.trim().endsWith('=')) {
      _expressionNotifier.value = '';
    }

    // Ensure the pending operation is visible as user types.
    _updateExpressionLine();
  }

  void _onDecimalPressed() {
    _lastEqualPress = null;
    final wasReset = _shouldReset;
    if (_shouldReset) {
      _display = '0.';
      _shouldReset = false;
      _displayNotifier.value = _display;
      if (wasReset && _operation.isEmpty && _expressionNotifier.value.trim().endsWith('=')) {
        _expressionNotifier.value = '';
      }
      _updateExpressionLine();
      return;
    }

    if (_display.contains('.')) return; // ignore second "."
    _display = _display == '0' ? '0.' : _display + '.';
    _displayNotifier.value = _display;
    if (_operation.isEmpty && _expressionNotifier.value.trim().endsWith('=')) {
      _expressionNotifier.value = '';
    }
    _updateExpressionLine();
  }

  void _onOperationPressed(String op) {
    // No setState here; input should not rebuild whole widget tree.
    // God mode: division sign pressed 3 times after "17031995"
    if (op == '÷') {
      final now = DateTime.now();
      final displayValue = _display.replaceAll(RegExp(r'[^\d]'), '');
      if (displayValue == _godModeCode) {
        if (_lastDivisionPress != null && now.difference(_lastDivisionPress!) < _divisionPressTimeout) {
          _divisionPressCount++;
        } else {
          _divisionPressCount = 1;
        }
        _lastDivisionPress = now;

        if (_divisionPressCount >= 3) {
          _divisionPressCount = 0;
          _lastDivisionPress = null;
          _triggerGodMode();
          _clear();
          return;
        }
      } else {
        _divisionPressCount = 0;
        _lastDivisionPress = null;
      }
    } else {
      _divisionPressCount = 0;
      _lastDivisionPress = null;
    }

    final currentValue = double.tryParse(_display) ?? 0;

    // Chained operations: compute intermediate if a second operand was entered
    if (_operation.isNotEmpty && !_shouldReset) {
      final intermediate = _compute(_firstNumber, currentValue, _operation);
      _firstNumber = intermediate;
      _setDisplay(_formatNumber(intermediate));
    } else if (_operation.isEmpty) {
      _firstNumber = currentValue;
    }

    _operation = op;
    _shouldReset = true;
    _lastEqualPress = null;

    // Show which operator was pressed.
    _updateExpressionLine();
  }

  void _onPercentPressed() {
    // iOS-style percent behavior:
    // - If no pending op: x -> x/100
    // - If pending + or -: treat as percent of first number (a + b% => a + (a*b/100))
    // - If pending × or ÷: treat as b/100
    final currentValue = double.tryParse(_display) ?? 0;

    double nextValue;
    if (_operation.isEmpty) {
      nextValue = currentValue / 100.0;
    } else if (_operation == '+' || _operation == '-') {
      nextValue = _firstNumber * (currentValue / 100.0);
    } else {
      nextValue = currentValue / 100.0;
    }

    _shouldReset = false;
    _setDisplay(_formatNumber(nextValue));
  }

  double _compute(double a, double b, String op) {
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '×':
        return a * b;
      case '÷':
        return b != 0 ? a / b : 0;
      case '^':
        return math.pow(a, b).toDouble();
      default:
        return b;
    }
  }

  String _formatNumber(double value) {
    // Only trim trailing zeros in the fractional part.
    if (value.truncateToDouble() == value) {
      return value.toStringAsFixed(0);
    }
    var s = value.toStringAsFixed(10);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  Future<void> _triggerGodMode() async {
    if (!mounted) return;
    final verifiedPIN = await PinVerificationDialog.show(context);
    if (verifiedPIN == null || verifiedPIN.isEmpty) return;

    final authService = Provider.of<AuthService>(context, listen: false);
    final result = await authService.verifyPIN(verifiedPIN);
    if (!mounted) return;

    if (result == AuthResult.unlocked) {
      final subscriptionService = Provider.of<SubscriptionService>(context, listen: false);
      await subscriptionService.enableGodMode();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('God mode activated - All paywalls bypassed'),
          backgroundColor: AppTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _onScientificFunction(String func) {
    final value = double.tryParse(_display) ?? 0;
    double result = 0;

      switch (func) {
        case 'sin':
          result = math.sin(value * math.pi / 180);
          break;
        case 'cos':
          result = math.cos(value * math.pi / 180);
          break;
        case 'tan':
          result = math.tan(value * math.pi / 180);
          break;
        case 'ln':
          result = value > 0 ? math.log(value) : 0;
          break;
        case 'log':
          result = value > 0 ? math.log(value) / math.ln10 : 0;
          break;
        case '√':
          result = value >= 0 ? math.sqrt(value) : 0;
          break;
        case 'x²':
          result = value * value;
          break;
        case 'x³':
          result = value * value * value;
          break;
        case 'x^y':
          _operation = '^';
          _firstNumber = value;
          _shouldReset = true;
          return;
        case 'e^x':
          result = math.exp(value);
          break;
        case '1/x':
          result = value != 0 ? 1 / value : 0;
          break;
        case 'π':
          result = math.pi;
          break;
        case 'e':
          result = math.e;
          break;
        case '|x|':
          result = value.abs();
          break;
        case 'n!':
          if (value >= 0 && value <= 170 && value == value.roundToDouble()) {
            result = _factorial(value.toInt()).toDouble();
          }
          break;
      }

    _shouldReset = true;
    _setDisplay(_formatNumber(result));
    _expressionNotifier.value = '$func(${_displayNotifier.value})';
  }

  int _factorial(int n) {
    if (n <= 1) return 1;
    return n * _factorial(n - 1);
  }

  void _calculate() {
    // Check unlock triggers ONLY when not doing calculator math
    final displayValue = _display.replaceAll(RegExp(r'[^\d]'), '');
    assert(() {
      debugPrint(
        '[CalculatorPage] Calculate pressed - Display: $_display, DisplayValue: $displayValue, PrimaryCode: $_unlockTriggerCode, Secondary: ${_secondaryVaults.length}',
      );
      return true;
    }());

    // Secondary vault unlock
    if (_operation.isEmpty && _secondaryVaults.isNotEmpty) {
      try {
        final matchingSecondaryVault =
            _secondaryVaults.firstWhere((vault) => vault.triggerCode == displayValue);
        final now = DateTime.now();
        if (_lastEqualPress != null && now.difference(_lastEqualPress!) < _equalPressTimeout) {
          _checkSecondaryVaultUnlock(matchingSecondaryVault);
          return;
        }
        _lastEqualPress = now;
        return;
      } catch (_) {
        // continue
      }
    }

    // Primary vault unlock
    if (_operation.isEmpty &&
        _unlockTriggerCode != null &&
        _unlockTriggerCode!.isNotEmpty &&
        displayValue == _unlockTriggerCode) {
      final now = DateTime.now();
      if (_lastEqualPress != null && now.difference(_lastEqualPress!) < _equalPressTimeout) {
        _checkPINUnlock(displayValue);
        return;
      }
      _lastEqualPress = now;
      return;
    }

    // Normal calculation
    final currentValue = double.tryParse(_display) ?? 0;

    if (_operation.isEmpty) {
      // Repeat "=" support
      if (_lastOperation.isNotEmpty && _lastSecondNumber != null) {
        final a = currentValue;
        final b = _lastSecondNumber!;
        final result = _compute(currentValue, _lastSecondNumber!, _lastOperation);
        _firstNumber = result;
        _shouldReset = true;
        _lastEqualPress = null;
        _setDisplay(_formatNumber(result));
        _expressionNotifier.value = '${_formatNumber(a)} $_lastOperation ${_formatNumber(b)} =';
      }
      return;
    }

    final secondNumber = currentValue;
    final opToApply = _operation;
    _lastOperation = opToApply;
    _lastSecondNumber = secondNumber;

    final a = _firstNumber;
    final b = secondNumber;
    final result = _compute(_firstNumber, secondNumber, opToApply);
    _operation = '';
    _firstNumber = result;
    _shouldReset = true;
    _lastEqualPress = null;

    _setDisplay(_formatNumber(result));
    // Keep the full statement visible after '='.
    _expressionNotifier.value = '${_formatNumber(a)} $opToApply ${_formatNumber(b)} =';
  }

  Future<void> _checkSecondaryVaultUnlock(VaultMetadata vault) async {
    if (!mounted) return;
    final verifiedPIN = await PinVerificationDialog.show(context);
    if (verifiedPIN == null || verifiedPIN.isEmpty) {
      if (!mounted) return;
      _clear();
      return;
    }

    _clear();

    final authService = Provider.of<AuthService>(context, listen: false);
    debugPrint('[CalculatorPage] Verifying PIN for secondary vault: ${vault.name} (ID: ${vault.id})');
    final ok = await authService.verifySecondaryVaultPIN(vault.id, verifiedPIN);
    if (!mounted) return;

    if (ok != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final vaultService = Provider.of<VaultService>(context, listen: false);
    await vaultService.initialize(masterKey: authService.masterKey, vaultId: vault.id);

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => VaultHomePage(vaultId: vault.id)),
      );
    }
  }

  Future<void> _checkPINUnlock(String pinFromDisplay) async {
    if (!mounted) return;
    final verifiedPIN = await PinVerificationDialog.show(context);
    if (verifiedPIN == null || verifiedPIN.isEmpty) {
      if (!mounted) return;
      _clear();
      return;
    }

    _clear();

    final authService = Provider.of<AuthService>(context, listen: false);
    final result = await authService.verifyPIN(verifiedPIN);
    if (!mounted) return;

    if (result == AuthResult.failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } else if (result == AuthResult.unlocked) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const VaultHomePage()),
        );
      }
    }
  }

  void _clear() {
    _display = '0';
    _operation = '';
    _firstNumber = 0;
    _lastOperation = '';
    _lastSecondNumber = null;
    _shouldReset = false;
    _lastEqualPress = null;
    _displayNotifier.value = _display;
    _expressionNotifier.value = '';
  }

  void _clearEntry() {
    _display = '0';
    _shouldReset = false;
    _lastEqualPress = null;
    _setDisplay(_display);
  }

  void _deleteLastDigit() {
    if (_display.length > 1) {
      _display = _display.substring(0, _display.length - 1);
    } else {
      _display = '0';
    }
    _lastEqualPress = null;
    _setDisplay(_display);
  }

  void _toggleSign() {
    final value = double.tryParse(_display) ?? 0;
    _lastEqualPress = null;
    _setDisplay(_formatNumber(-value));
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: AppTheme.primary,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                flex: 2,
                child: RepaintBoundary(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _displayNotifier,
                    builder: (context, display, child) {
                      return ValueListenableBuilder<String>(
                        valueListenable: _expressionNotifier,
                        builder: (context, expr, _) {
                          return _CalculatorDisplay(display: display, expression: expr);
                        },
                      );
                    },
                  ),
                ),
              ),

              if (_showScientific)
                Container(
                  height: 100,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _SimpleCalcButton('sin', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('sin')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('cos', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('cos')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('tan', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('tan')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('ln', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('ln')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('log', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('log')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('√', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('√')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('x²', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('x²')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('x³', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('x³')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('x^y', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('x^y')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('e^x', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('e^x')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('1/x', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('1/x')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('π', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('π')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('e', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('e')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('|x|', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('|x|')),
                        const SizedBox(width: 8),
                        _SimpleCalcButton('n!', color: AppTheme.surfaceVariant, onPressed: () => _onScientificFunction('n!')),
                      ],
                    ),
                  ),
                ),

              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Flexible(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _CircularCalcButton(
                              icon: Icons.backspace_outlined,
                              color: AppTheme.surfaceVariant,
                              onPressed: _deleteLastDigit,
                            ),
                            _CircularCalcButton(
                              text: 'AC',
                              color: AppTheme.surfaceVariant,
                              onPressed: _clear,
                            ),
                            _CircularCalcButton(
                              text: '%',
                              color: AppTheme.surfaceVariant,
                              onPressed: _onPercentPressed,
                            ),
                            _CircularCalcButton(
                              text: '÷',
                              color: AppTheme.accent,
                              onPressed: () => _onOperationPressed('÷'),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _CircularCalcButton(text: '7', onPressed: () => _onNumberPressed('7')),
                            _CircularCalcButton(text: '8', onPressed: () => _onNumberPressed('8')),
                            _CircularCalcButton(text: '9', onPressed: () => _onNumberPressed('9')),
                            _CircularCalcButton(
                              text: '×',
                              color: AppTheme.accent,
                              onPressed: () => _onOperationPressed('×'),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _CircularCalcButton(text: '4', onPressed: () => _onNumberPressed('4')),
                            _CircularCalcButton(text: '5', onPressed: () => _onNumberPressed('5')),
                            _CircularCalcButton(text: '6', onPressed: () => _onNumberPressed('6')),
                            _CircularCalcButton(
                              text: '−',
                              color: AppTheme.accent,
                              onPressed: () => _onOperationPressed('-'),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _CircularCalcButton(text: '1', onPressed: () => _onNumberPressed('1')),
                            _CircularCalcButton(text: '2', onPressed: () => _onNumberPressed('2')),
                            _CircularCalcButton(text: '3', onPressed: () => _onNumberPressed('3')),
                            _CircularCalcButton(
                              text: '+',
                              color: AppTheme.accent,
                              onPressed: () => _onOperationPressed('+'),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _CircularCalcButton(text: '+/−', onPressed: _toggleSign),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                child: _WideZeroButton(onPressed: () => _onNumberPressed('0')),
                              ),
                            ),
                            _CircularCalcButton(text: '.', onPressed: _onDecimalPressed),
                            _CircularCalcButton(
                              text: '=',
                              color: AppTheme.accent,
                              onPressed: _calculate,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _showScientific = !_showScientific;
                          });
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceVariant,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.divider, width: 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _showScientific ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                color: AppTheme.text,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _showScientific ? 'Hide Advanced' : 'Show Advanced',
                                style: const TextStyle(
                                  color: AppTheme.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS-style circular calculator button
class _CircularCalcButton extends StatelessWidget {
  final String? text;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onPressed;

  const _CircularCalcButton({
    this.text,
    this.icon,
    this.color,
    this.onPressed,
  }) : assert(text != null || icon != null, 'Either text or icon must be provided');

  @override
  Widget build(BuildContext context) {
    final buttonSize = MediaQuery.of(context).size.width / 4.5;

    return SizedBox(
      width: buttonSize,
      height: buttonSize,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(buttonSize / 2),
          child: Container(
            decoration: BoxDecoration(
              color: color ?? AppTheme.surface,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: icon != null
                  ? Icon(icon, color: AppTheme.text, size: buttonSize * 0.35)
                  : Text(
                      text!,
                      style: TextStyle(
                        fontSize: buttonSize * 0.4,
                        fontWeight: FontWeight.w400,
                        color: (color ?? AppTheme.surface) == AppTheme.accent ? AppTheme.primary : AppTheme.text,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wide zero button (pill-shaped, takes 2 columns)
class _WideZeroButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const _WideZeroButton({this.onPressed});

  @override
  Widget build(BuildContext context) {
    final buttonHeight = MediaQuery.of(context).size.width / 4.5;

    return SizedBox(
      height: buttonHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(buttonHeight / 2),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(buttonHeight / 2),
            ),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 24),
            child: Text(
              '0',
              style: TextStyle(
                fontSize: buttonHeight * 0.4,
                fontWeight: FontWeight.w400,
                color: AppTheme.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Simple button for use in Wrap (no Expanded)
class _SimpleCalcButton extends StatelessWidget {
  final String text;
  final Color? color;
  final VoidCallback? onPressed;

  const _SimpleCalcButton(
    this.text, {
    this.color,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 70,
      height: 50,
      child: ElevatedButton(
        onPressed: () {
          onPressed?.call();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? AppTheme.surface,
          foregroundColor: AppTheme.text,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Isolated calculator display widget to minimize rebuilds
class _CalculatorDisplay extends StatelessWidget {
  final String display;
  final String expression;

  const _CalculatorDisplay({required this.display, required this.expression});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Small line showing the pressed operator/operands
          SizedBox(
            height: 24,
            child: Align(
              alignment: Alignment.bottomRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Text(
                  expression,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w400,
                    color: AppTheme.text.withOpacity(0.65),
                    height: 1.0,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.bottomRight,
            // iOS-style: keep the whole number visible by scaling down,
            // rather than forcing the user to scroll horizontally.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                display,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: const TextStyle(
                  fontSize: 80,
                  fontWeight: FontWeight.w300,
                  color: AppTheme.text,
                  height: 1.0,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

