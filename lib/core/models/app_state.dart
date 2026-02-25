/// Application state enum for routing and UI decisions
enum AppState {
  /// First-time user onboarding
  onboarding,
  
  /// PIN setup screen
  pinSetup,
  
  /// Disguised calculator interface
  disguised,
  
  /// Vault is locked (requires PIN)
  locked,
  
  /// Vault is unlocked and accessible
  unlocked,
}
