import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Service for caching decrypted thumbnails to improve performance
class ThumbnailCacheService {
  static final ThumbnailCacheService _instance = ThumbnailCacheService._internal();
  factory ThumbnailCacheService() => _instance;
  ThumbnailCacheService._internal();
  
  Directory? _cacheDirectory;
  final Map<String, Uint8List> _memoryCache = {};
  final int _maxMemoryCacheSize = 50; // Max items in memory cache
  final int _maxCacheSizeMB = 100; // Max cache size in MB
  
  /// Initialize cache directory
  Future<void> initialize() async {
    if (_cacheDirectory != null) return;
    
    final tempDir = await getTemporaryDirectory();
    _cacheDirectory = Directory('${tempDir.path}/thumbnail_cache');
    
    if (!await _cacheDirectory!.exists()) {
      await _cacheDirectory!.create(recursive: true);
    }
    
    // Clean old cache on startup
    _cleanOldCache();
  }
  
  /// Get cache key for thumbnail
  String _getCacheKey(String itemId, String? thumbnailId) {
    final key = thumbnailId ?? itemId;
    final bytes = utf8.encode(key);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }
  
  /// Get thumbnail from cache (memory first, then disk)
  Future<Uint8List?> getThumbnail(String itemId, String? thumbnailId) async {
    await initialize();
    
    final cacheKey = _getCacheKey(itemId, thumbnailId);
    
    // Check memory cache first
    if (_memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey];
    }
    
    // Check disk cache
    try {
      final cacheFile = File('${_cacheDirectory!.path}/$cacheKey.thumb');
      if (await cacheFile.exists()) {
        final data = await cacheFile.readAsBytes();
        
        // Add to memory cache
        _addToMemoryCache(cacheKey, data);
        
        return data;
      }
    } catch (e) {
      debugPrint('Error reading thumbnail from cache: $e');
    }
    
    return null;
  }
  
  /// Store thumbnail in cache (memory and disk)
  Future<void> storeThumbnail(String itemId, String? thumbnailId, Uint8List thumbnailData) async {
    await initialize();
    
    final cacheKey = _getCacheKey(itemId, thumbnailId);
    
    // Store in memory cache
    _addToMemoryCache(cacheKey, thumbnailData);
    
    // Store in disk cache asynchronously
    try {
      final cacheFile = File('${_cacheDirectory!.path}/$cacheKey.thumb');
      await cacheFile.writeAsBytes(thumbnailData);
    } catch (e) {
      debugPrint('Error storing thumbnail in cache: $e');
    }
  }
  
  /// Add to memory cache with size limit
  void _addToMemoryCache(String key, Uint8List data) {
    // Remove oldest entries if cache is full
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      final firstKey = _memoryCache.keys.first;
      _memoryCache.remove(firstKey);
    }
    
    _memoryCache[key] = data;
  }
  
  /// Clear cache for specific item
  Future<void> clearCache(String itemId, String? thumbnailId) async {
    await initialize();
    
    final cacheKey = _getCacheKey(itemId, thumbnailId);
    
    // Remove from memory cache
    _memoryCache.remove(cacheKey);
    
    // Remove from disk cache
    try {
      final cacheFile = File('${_cacheDirectory!.path}/$cacheKey.thumb');
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (e) {
      debugPrint('Error clearing thumbnail cache: $e');
    }
  }
  
  /// Clear all cache
  Future<void> clearAllCache() async {
    await initialize();
    
    // Clear memory cache
    _memoryCache.clear();
    
    // Clear disk cache
    try {
      if (await _cacheDirectory!.exists()) {
        await for (final entity in _cacheDirectory!.list()) {
          if (entity is File && entity.path.endsWith('.thumb')) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('Error clearing all thumbnail cache: $e');
    }
  }
  
  /// Clean old cache files (older than 7 days)
  Future<void> _cleanOldCache() async {
    try {
      if (!await _cacheDirectory!.exists()) return;
      
      final now = DateTime.now();
      final maxAge = const Duration(days: 7);
      
      int totalSize = 0;
      final filesToDelete = <File>[];
      
      await for (final entity in _cacheDirectory!.list()) {
        if (entity is File && entity.path.endsWith('.thumb')) {
          final stat = await entity.stat();
          totalSize += stat.size;
          
          // Check if file is too old
          if (now.difference(stat.modified) > maxAge) {
            filesToDelete.add(entity);
          }
        }
      }
      
      // Delete old files
      for (final file in filesToDelete) {
        await file.delete();
      }
      
      // If cache is too large, delete oldest files
      final maxSizeBytes = _maxCacheSizeMB * 1024 * 1024;
      if (totalSize > maxSizeBytes) {
        final files = <File>[];
        final fileStats = <MapEntry<File, FileStat>>[];
        
        await for (final entity in _cacheDirectory!.list()) {
          if (entity is File && entity.path.endsWith('.thumb')) {
            final stat = await entity.stat();
            fileStats.add(MapEntry(entity, stat));
          }
        }
        
        // Sort by modification time (oldest first)
        fileStats.sort((a, b) => a.value.modified.compareTo(b.value.modified));
        
        // Delete oldest files until under limit
        int currentSize = totalSize;
        for (final entry in fileStats) {
          if (currentSize <= maxSizeBytes) break;
          
          currentSize -= entry.value.size;
          await entry.key.delete();
        }
      }
    } catch (e) {
      debugPrint('Error cleaning thumbnail cache: $e');
    }
  }
  
  /// Get cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    await initialize();
    
    int fileCount = 0;
    int totalSize = 0;
    
    try {
      if (await _cacheDirectory!.exists()) {
        await for (final entity in _cacheDirectory!.list()) {
          if (entity is File && entity.path.endsWith('.thumb')) {
            fileCount++;
            final stat = await entity.stat();
            totalSize += stat.size;
          }
        }
      }
    } catch (e) {
      debugPrint('Error getting cache stats: $e');
    }
    
    return {
      'memoryCacheSize': _memoryCache.length,
      'diskCacheFiles': fileCount,
      'diskCacheSizeMB': (totalSize / (1024 * 1024)).toStringAsFixed(2),
    };
  }
}
