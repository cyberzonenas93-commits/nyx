import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage interactive tutorial state
class TutorialService extends ChangeNotifier {
  static const String _vaultTutorialCompletedKey = 'vault_tutorial_completed';
  static const String _currentTutorialStepKey = 'current_tutorial_step';
  
  bool _vaultTutorialCompleted = false;
  int _currentStep = 0;
  
  bool get vaultTutorialCompleted => _vaultTutorialCompleted;
  int get currentStep => _currentStep;
  
  TutorialService() {
    _loadTutorialState();
  }
  
  Future<void> _loadTutorialState() async {
    final prefs = await SharedPreferences.getInstance();
    _vaultTutorialCompleted = prefs.getBool(_vaultTutorialCompletedKey) ?? false;
    _currentStep = prefs.getInt(_currentTutorialStepKey) ?? 0;
    notifyListeners();
  }
  
  Future<void> markTutorialCompleted() async {
    _vaultTutorialCompleted = true;
    _currentStep = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_vaultTutorialCompletedKey, true);
    await prefs.setInt(_currentTutorialStepKey, 0);
    notifyListeners();
  }
  
  Future<void> resetTutorial() async {
    _vaultTutorialCompleted = false;
    _currentStep = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_vaultTutorialCompletedKey, false);
    await prefs.setInt(_currentTutorialStepKey, 0);
    notifyListeners();
  }
  
  Future<void> setCurrentStep(int step) async {
    _currentStep = step;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_currentTutorialStepKey, step);
    notifyListeners();
  }
  
  Future<void> startTutorial() async {
    _vaultTutorialCompleted = false;
    _currentStep = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_vaultTutorialCompletedKey, false);
    await prefs.setInt(_currentTutorialStepKey, 0);
    notifyListeners();
  }
}
