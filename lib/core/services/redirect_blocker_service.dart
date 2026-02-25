import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

/// Redirect decision enum
enum RedirectDecision {
  allow,
  block,
  askUser,
}

/// Service that intelligently blocks spammy redirects
class RedirectBlockerService extends ChangeNotifier {
  static final RedirectBlockerService _instance = RedirectBlockerService._internal();
  factory RedirectBlockerService() => _instance;
  RedirectBlockerService._internal() {
    loadEnabledState();
  }
  
  bool _isEnabled = true; // Default to enabled
  
  /// Check if redirect blocker is enabled
  bool get isEnabled => _isEnabled;
  
  /// Load enabled state from preferences
  Future<void> loadEnabledState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool('redirect_blocker_enabled') ?? true; // Default to enabled
      notifyListeners();
    } catch (e) {
      debugPrint('[RedirectBlocker] Error loading enabled state: $e');
      _isEnabled = true; // Default to enabled on error
    }
  }
  
  /// Enable redirect blocker
  Future<void> enable() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('redirect_blocker_enabled', true);
      _isEnabled = true;
      notifyListeners();
      debugPrint('[RedirectBlocker] Redirect blocker enabled');
    } catch (e) {
      debugPrint('[RedirectBlocker] Error enabling: $e');
    }
  }
  
  /// Disable redirect blocker
  Future<void> disable() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('redirect_blocker_enabled', false);
      _isEnabled = false;
      notifyListeners();
      debugPrint('[RedirectBlocker] Redirect blocker disabled');
    } catch (e) {
      debugPrint('[RedirectBlocker] Error disabling: $e');
    }
  }
  
  /// Toggle redirect blocker
  Future<void> toggle() async {
    if (_isEnabled) {
      await disable();
    } else {
      await enable();
    }
  }

  // Track redirect history per tab/session
  final Map<String, List<RedirectInfo>> _redirectHistory = {};
  
  // Suspicious domain patterns
  final List<String> _suspiciousPatterns = [
    'bit.ly',
    'tinyurl.com',
    'goo.gl',
    't.co',
    'ow.ly',
    'is.gd',
    'buff.ly',
    'adf.ly',
    'bc.vc',
    'ouo.io',
    'shorte.st',
    'adfly',
    'linkbucks',
    'doubleclick',
    'googleads',
    'adsense',
    'popads',
    'popcash',
    'propellerads',
    'outbrain',
    'taboola',
    'revcontent',
    'adclick',
    'adserver',
    'advertising',
    'affiliate',
    'clickbank',
    'commission',
    'redirect',
    'tracking',
    'analytics',
    'pixel',
    'beacon',
    'spyware',
    'malware',
    'phishing',
    'scam',
    'fraud',
    'spam',
  ];

  // Known good domains (whitelist)
  final Set<String> _trustedDomains = {
    'google.com',
    'youtube.com',
    'facebook.com',
    'twitter.com',
    'instagram.com',
    'reddit.com',
    'github.com',
    'stackoverflow.com',
    'wikipedia.org',
    'amazon.com',
    'microsoft.com',
    'apple.com',
    'netflix.com',
    'spotify.com',
    'discord.com',
    'twitch.tv',
  };

  /// Check if a redirect should be blocked
  RedirectDecision shouldBlockRedirect({
    required String fromUrl,
    required String toUrl,
    required String tabId,
    bool isUserInitiated = false,
  }) {
    // If redirect blocker is disabled, allow all redirects
    if (!_isEnabled) {
      return RedirectDecision.allow;
    }
    
    try {
      final fromDomain = _extractDomain(fromUrl);
      final toDomain = _extractDomain(toUrl);

      // Always allow if user initiated (clicked a link or typed URL)
      if (isUserInitiated) {
        debugPrint('[RedirectBlocker] Allowing user-initiated navigation: $toUrl');
        return RedirectDecision.allow;
      }

      // Same domain redirects are usually safe
      if (fromDomain == toDomain || fromDomain.isEmpty || toDomain.isEmpty) {
        return RedirectDecision.allow;
      }

      // Check if destination is trusted
      if (_isTrustedDomain(toDomain)) {
        debugPrint('[RedirectBlocker] Allowing trusted domain: $toDomain');
        return RedirectDecision.allow;
      }

      // Check for suspicious patterns FIRST (most aggressive blocking)
      if (_hasSuspiciousPattern(toUrl)) {
        debugPrint('[RedirectBlocker] Blocking suspicious URL pattern: $toUrl');
        return RedirectDecision.block;
      }
      
      // Check for suspicious domain patterns
      if (_hasSuspiciousPattern(toDomain)) {
        debugPrint('[RedirectBlocker] Blocking suspicious domain pattern: $toDomain');
        return RedirectDecision.block;
      }

      // Track redirect history
      if (!_redirectHistory.containsKey(tabId)) {
        _redirectHistory[tabId] = [];
      }

      final redirectInfo = RedirectInfo(
        fromUrl: fromUrl,
        toUrl: toUrl,
        timestamp: DateTime.now(),
      );

      _redirectHistory[tabId]!.add(redirectInfo);

      // Clean old redirects (keep only last 10 seconds)
      _redirectHistory[tabId]!.removeWhere(
        (info) => DateTime.now().difference(info.timestamp).inSeconds > 10,
      );

      // Check for redirect loops (too many redirects in short time)
      if (_redirectHistory[tabId]!.length > 5) {
        debugPrint('[RedirectBlocker] Blocking redirect loop detected');
        return RedirectDecision.block;
      }

      // Check for rapid cross-domain redirects
      final recentRedirects = _redirectHistory[tabId]!
          .where((info) => DateTime.now().difference(info.timestamp).inSeconds < 3)
          .toList();

      if (recentRedirects.length >= 3) {
        final uniqueDomains = recentRedirects
            .map((info) => _extractDomain(info.toUrl))
            .toSet();
        
        if (uniqueDomains.length >= 3) {
          debugPrint('[RedirectBlocker] Blocking rapid cross-domain redirects');
          return RedirectDecision.block;
        }
      }

      // Check if redirecting to a completely different domain without user interaction
      if (!_isRelatedDomain(fromDomain, toDomain)) {
        debugPrint('[RedirectBlocker] Asking user for cross-domain redirect: $toDomain');
        return RedirectDecision.askUser;
      }

      return RedirectDecision.allow;
    } catch (e) {
      debugPrint('[RedirectBlocker] Error checking redirect: $e');
      // On error, allow redirect (fail open)
      return RedirectDecision.allow;
    }
  }

  /// Extract domain from URL
  String _extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      var host = uri.host.toLowerCase();
      
      // Remove www. prefix
      if (host.startsWith('www.')) {
        host = host.substring(4);
      }
      
      // Extract base domain (e.g., example.com from sub.example.com)
      final parts = host.split('.');
      if (parts.length >= 2) {
        return '${parts[parts.length - 2]}.${parts[parts.length - 1]}';
      }
      
      return host;
    } catch (e) {
      debugPrint('[RedirectBlocker] Error extracting domain: $e');
      return '';
    }
  }

  /// Check if domain is trusted
  bool _isTrustedDomain(String domain) {
    return _trustedDomains.contains(domain) ||
        _trustedDomains.any((trusted) => domain.endsWith('.$trusted') || domain == trusted);
  }

  /// Check if URL has suspicious patterns
  bool _hasSuspiciousPattern(String url) {
    final urlLower = url.toLowerCase();
    return _suspiciousPatterns.any((pattern) => urlLower.contains(pattern));
  }

  /// Check if domains are related (same base domain or known related)
  bool _isRelatedDomain(String fromDomain, String toDomain) {
    if (fromDomain == toDomain) return true;
    
    // Check if same base domain (e.g., example.com and sub.example.com)
    if (fromDomain.endsWith(toDomain) || toDomain.endsWith(fromDomain)) {
      return true;
    }
    
    // Known related domains
    final relatedGroups = [
      {'google.com', 'youtube.com', 'gmail.com', 'googleusercontent.com'},
      {'facebook.com', 'instagram.com', 'whatsapp.com'},
      {'microsoft.com', 'live.com', 'outlook.com', 'office.com'},
      {'amazon.com', 'aws.amazon.com'},
    ];
    
    for (final group in relatedGroups) {
      if (group.contains(fromDomain) && group.contains(toDomain)) {
        return true;
      }
    }
    
    return false;
  }

  /// Clear redirect history for a tab
  void clearHistory(String tabId) {
    _redirectHistory.remove(tabId);
  }

  /// Clear all redirect history
  void clearAllHistory() {
    _redirectHistory.clear();
  }

  /// Add a domain to trusted list
  void addTrustedDomain(String domain) {
    _trustedDomains.add(domain.toLowerCase());
    notifyListeners();
  }

  /// Remove a domain from trusted list
  void removeTrustedDomain(String domain) {
    _trustedDomains.remove(domain.toLowerCase());
    notifyListeners();
  }
}

/// Information about a redirect
class RedirectInfo {
  final String fromUrl;
  final String toUrl;
  final DateTime timestamp;

  RedirectInfo({
    required this.fromUrl,
    required this.toUrl,
    required this.timestamp,
  });
}
