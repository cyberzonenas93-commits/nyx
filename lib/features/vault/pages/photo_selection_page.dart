import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../app/theme.dart';

/// Custom photo selection page with Select All functionality
class PhotoSelectionPage extends StatefulWidget {
  final int? maxSelection;

  const PhotoSelectionPage({
    super.key,
    this.maxSelection,
  });

  @override
  State<PhotoSelectionPage> createState() => _PhotoSelectionPageState();
}

class _PhotoSelectionPageState extends State<PhotoSelectionPage> {
  List<AssetEntity> _assets = [];
  final Set<String> _selectedAssetIds = {};
  bool _isLoading = true;
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    try {
      // Request permission
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        if (!mounted) return;
        setState(() {
          _hasPermission = false;
          _isLoading = false;
        });
        return;
      }

      // Get all photos
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
      );

      if (!mounted) return;

      if (albums.isEmpty) {
        setState(() {
          _hasPermission = true;
          _assets = [];
          _isLoading = false;
        });
        return;
      }

      // Get assets from "All Photos" album (cap for performance)
      final allPhotosAlbum = albums.first;
      final total = await allPhotosAlbum.assetCountAsync;
      final end = total > 2000 ? 2000 : total;
      final assets = await allPhotosAlbum.getAssetListRange(start: 0, end: end);

      if (!mounted) return;
      setState(() {
        _hasPermission = true;
        _assets = assets;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[PhotoSelectionPage] Error loading photos: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _toggleSelection(String assetId) {
    setState(() {
      if (_selectedAssetIds.contains(assetId)) {
        _selectedAssetIds.remove(assetId);
      } else {
        if (widget.maxSelection != null && _selectedAssetIds.length >= widget.maxSelection!) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Maximum ${widget.maxSelection} photos can be selected'),
              backgroundColor: AppTheme.warning,
            ),
          );
          return;
        }
        _selectedAssetIds.add(assetId);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (widget.maxSelection != null) {
        _selectedAssetIds
          ..clear()
          ..addAll(_assets.take(widget.maxSelection!).map((a) => a.id));
      } else {
        _selectedAssetIds
          ..clear()
          ..addAll(_assets.map((a) => a.id));
      }
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedAssetIds.clear();
    });
  }

  bool get _allSelected {
    if (_assets.isEmpty) return false;
    if (widget.maxSelection != null) {
      return _selectedAssetIds.length == _assets.length || _selectedAssetIds.length == widget.maxSelection!;
    }
    return _selectedAssetIds.length == _assets.length;
  }

  Future<List<File>> _getSelectedFiles() async {
    final files = <File>[];
    for (final assetId in _selectedAssetIds) {
      final asset = _assets.firstWhere((a) => a.id == assetId);
      final file = await asset.file;
      if (file != null) files.add(file);
    }
    return files;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: Text(
          _selectedAssetIds.isEmpty ? 'Select Photos' : '${_selectedAssetIds.length} Selected',
        ),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        actions: [
          if (_assets.isNotEmpty)
            TextButton(
              onPressed: _allSelected ? _deselectAll : _selectAll,
              child: Text(
                _allSelected ? 'Deselect All' : 'Select All',
                style: const TextStyle(
                  color: AppTheme.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _selectedAssetIds.isNotEmpty
          ? Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_selectedAssetIds.length} photo${_selectedAssetIds.length == 1 ? '' : 's'} selected',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        final files = await _getSelectedFiles();
                        if (!mounted) return;
                        Navigator.of(context).pop(files);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: AppTheme.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      child: const Text(
                        'Import',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.accent),
      );
    }

    if (!_hasPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_library_outlined, size: 64, color: AppTheme.text.withOpacity(0.4)),
              const SizedBox(height: 24),
              const Text(
                'Photo Access Required',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Please grant photo library access to import photos.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.text.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  PhotoManager.openSetting();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text(
                  'Open Settings',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_assets.isEmpty) {
      return Center(
        child: Text(
          'No photos found.',
          style: TextStyle(color: AppTheme.text.withOpacity(0.8)),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _assets.length,
      itemBuilder: (context, index) {
        final asset = _assets[index];
        final isSelected = _selectedAssetIds.contains(asset.id);

        return GestureDetector(
          onTap: () => _toggleSelection(asset.id),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  if (data != null) {
                    return Image.memory(data, fit: BoxFit.cover);
                  }
                  return Container(
                    color: AppTheme.surface,
                    child: Icon(Icons.image_outlined, color: AppTheme.text.withOpacity(0.3)),
                  );
                },
              ),
              if (isSelected)
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.accent, width: 3),
                  ),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: AppTheme.accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check, color: AppTheme.primary, size: 16),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

