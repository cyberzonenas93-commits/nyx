import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Browser session data model
class BrowserSession {
  final String id;
  final String url;
  final String title;
  final bool isIncognito;
  final int timestamp;
  
  BrowserSession({
    required this.id,
    required this.url,
    required this.title,
    required this.isIncognito,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'isIncognito': isIncognito,
    'timestamp': timestamp,
  };
  
  factory BrowserSession.fromJson(Map<String, dynamic> json) => BrowserSession(
    id: json['id'] as String,
    url: json['url'] as String,
    title: json['title'] as String,
    isIncognito: json['isIncognito'] as bool,
    timestamp: json['timestamp'] as int,
  );
}

/// Browser history entry
class BrowserHistoryEntry {
  final String url;
  final String title;
  final int timestamp;
  
  BrowserHistoryEntry({
    required this.url,
    required this.title,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'timestamp': timestamp,
  };
  
  factory BrowserHistoryEntry.fromJson(Map<String, dynamic> json) => BrowserHistoryEntry(
    url: json['url'] as String,
    title: json['title'] as String,
    timestamp: json['timestamp'] as int,
  );
}

/// Browser bookmark entry
class BrowserBookmark {
  final String url;
  final String title;
  final int timestamp;
  
  BrowserBookmark({
    required this.url,
    required this.title,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'timestamp': timestamp,
  };
  
  factory BrowserBookmark.fromJson(Map<String, dynamic> json) => BrowserBookmark(
    url: json['url'] as String,
    title: json['title'] as String,
    timestamp: json['timestamp'] as int,
  );
}

/// Service for managing browser sessions and history
class BrowserSessionService extends ChangeNotifier {
  static const String _sessionsKey = 'browser_sessions';
  static const String _currentTabIndexKey = 'browser_current_tab_index';
  static const String _historyKey = 'browser_history';
  static const String _bookmarksKey = 'browser_bookmarks';
  static const int _maxHistoryEntries = 1000;
  
  List<BrowserSession> _sessions = [];
  int _currentTabIndex = 0;
  List<BrowserHistoryEntry> _history = [];
  List<BrowserBookmark> _bookmarks = [];
  
  List<BrowserSession> get sessions => List.unmodifiable(_sessions);
  int get currentTabIndex => _currentTabIndex;
  List<BrowserHistoryEntry> get history => List.unmodifiable(_history);
  List<BrowserBookmark> get bookmarks => List.unmodifiable(_bookmarks);
  
  BrowserSessionService() {
    _loadSessions();
    _loadHistory();
    _loadBookmarks();
  }
  
  /// Load saved sessions from storage
  Future<void> _loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionsJson = prefs.getString(_sessionsKey);
      final currentIndex = prefs.getInt(_currentTabIndexKey) ?? 0;
      
      if (sessionsJson != null) {
        final List<dynamic> sessionsList = jsonDecode(sessionsJson);
        _sessions = sessionsList.map((s) => BrowserSession.fromJson(s as Map<String, dynamic>)).toList();
      }
      
      _currentTabIndex = currentIndex;
      if (_currentTabIndex >= _sessions.length) {
        _currentTabIndex = _sessions.length > 0 ? _sessions.length - 1 : 0;
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error loading sessions: $e');
    }
  }
  
  /// Save sessions to storage
  Future<void> saveSessions(List<BrowserSession> sessions, int currentTabIndex) async {
    try {
      _sessions = sessions;
      _currentTabIndex = currentTabIndex;
      
      final prefs = await SharedPreferences.getInstance();
      final sessionsJson = jsonEncode(sessions.map((s) => s.toJson()).toList());
      await prefs.setString(_sessionsKey, sessionsJson);
      await prefs.setInt(_currentTabIndexKey, currentTabIndex);
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error saving sessions: $e');
    }
  }
  
  /// Load history from storage
  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_historyKey);
      
      if (historyJson != null) {
        final List<dynamic> historyList = jsonDecode(historyJson);
        _history = historyList.map((h) => BrowserHistoryEntry.fromJson(h as Map<String, dynamic>)).toList();
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error loading history: $e');
    }
  }
  
  /// Add entry to history
  Future<void> addHistoryEntry(String url, String title) async {
    try {
      // Remove duplicate entries for the same URL
      _history.removeWhere((entry) => entry.url == url);
      
      // Add new entry at the beginning
      _history.insert(0, BrowserHistoryEntry(
        url: url,
        title: title,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      
      // Limit history size
      if (_history.length > _maxHistoryEntries) {
        _history = _history.sublist(0, _maxHistoryEntries);
      }
      
      // Save to storage
      final prefs = await SharedPreferences.getInstance();
      final historyJson = jsonEncode(_history.map((h) => h.toJson()).toList());
      await prefs.setString(_historyKey, historyJson);
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error adding history entry: $e');
    }
  }
  
  /// Clear history
  Future<void> clearHistory() async {
    try {
      _history.clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error clearing history: $e');
    }
  }
  
  /// Load bookmarks from storage
  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarksJson = prefs.getString(_bookmarksKey);
      
      if (bookmarksJson != null) {
        final List<dynamic> bookmarksList = jsonDecode(bookmarksJson);
        _bookmarks = bookmarksList.map((b) => BrowserBookmark.fromJson(b as Map<String, dynamic>)).toList();
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error loading bookmarks: $e');
    }
  }
  
  /// Add bookmark
  Future<void> addBookmark(String url, String title) async {
    try {
      // Check if bookmark already exists
      if (_bookmarks.any((b) => b.url == url)) {
        return; // Already bookmarked
      }
      
      // Add new bookmark
      _bookmarks.add(BrowserBookmark(
        url: url,
        title: title,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      
      // Save to storage
      final prefs = await SharedPreferences.getInstance();
      final bookmarksJson = jsonEncode(_bookmarks.map((b) => b.toJson()).toList());
      await prefs.setString(_bookmarksKey, bookmarksJson);
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error adding bookmark: $e');
    }
  }
  
  /// Remove bookmark
  Future<void> removeBookmark(String url) async {
    try {
      _bookmarks.removeWhere((b) => b.url == url);
      
      // Save to storage
      final prefs = await SharedPreferences.getInstance();
      final bookmarksJson = jsonEncode(_bookmarks.map((b) => b.toJson()).toList());
      await prefs.setString(_bookmarksKey, bookmarksJson);
      
      notifyListeners();
    } catch (e) {
      debugPrint('[BrowserSession] Error removing bookmark: $e');
    }
  }
  
  /// Check if URL is bookmarked
  bool isBookmarked(String url) {
    return _bookmarks.any((b) => b.url == url);
  }
  
  /// Search history
  List<BrowserHistoryEntry> searchHistory(String query) {
    if (query.isEmpty) return [];
    
    final lowerQuery = query.toLowerCase();
    return _history.where((entry) {
      return entry.title.toLowerCase().contains(lowerQuery) ||
             entry.url.toLowerCase().contains(lowerQuery);
    }).toList();
  }
}
