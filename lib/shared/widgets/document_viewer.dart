import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:open_filex/open_filex.dart';
import '../../app/theme.dart';

/// Document viewer for PDF and Office files
class DocumentViewer extends StatelessWidget {
  final File file;
  final String fileName;
  
  const DocumentViewer({
    super.key,
    required this.file,
    required this.fileName,
  });
  
  /// Determine file type from extension
  static DocumentType _getFileType(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    switch (extension) {
      case 'pdf':
        return DocumentType.pdf;
      case 'xlsx':
      case 'xls':
      case 'xlsm':
      case 'xlsb':
        return DocumentType.excel;
      case 'docx':
      case 'doc':
      case 'docm':
        return DocumentType.word;
      case 'pages':
        return DocumentType.pages;
      default:
        return DocumentType.unknown;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final fileType = _getFileType(fileName);
    
    switch (fileType) {
      case DocumentType.pdf:
        return _PDFViewer(file: file);
      case DocumentType.excel:
      case DocumentType.word:
      case DocumentType.pages:
        return _OfficeFileViewer(file: file, fileName: fileName, type: fileType);
      case DocumentType.unknown:
        return _UnknownFileViewer(file: file, fileName: fileName);
    }
  }
}

/// PDF viewer using Syncfusion PDF Viewer
class _PDFViewer extends StatelessWidget {
  final File file;
  
  const _PDFViewer({required this.file});
  
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surface,
      child: SfPdfViewer.file(
        file,
        enableDoubleTapZooming: true,
        enableTextSelection: true,
        pageLayoutMode: PdfPageLayoutMode.continuous,
        scrollDirection: PdfScrollDirection.vertical,
        onDocumentLoaded: (details) {
          debugPrint('PDF loaded: ${details.document.pages.count} pages');
        },
        onDocumentLoadFailed: (details) {
          debugPrint('PDF load failed: ${details.error}');
        },
      ),
    );
  }
}

/// Office file viewer - opens with system default app
class _OfficeFileViewer extends StatefulWidget {
  final File file;
  final String fileName;
  final DocumentType type;
  
  const _OfficeFileViewer({
    required this.file,
    required this.fileName,
    required this.type,
  });
  
  @override
  State<_OfficeFileViewer> createState() => _OfficeFileViewerState();
}

class _OfficeFileViewerState extends State<_OfficeFileViewer> {
  bool _isOpening = false;
  String? _errorMessage;
  
  @override
  void initState() {
    super.initState();
    _openFile();
  }
  
  Future<void> _openFile() async {
    setState(() {
      _isOpening = true;
      _errorMessage = null;
    });
    
    try {
      final result = await OpenFilex.open(widget.file.path);
      
      if (mounted) {
        setState(() {
          _isOpening = false;
          
          if (result.type != ResultType.done) {
            _errorMessage = _getErrorMessage(result);
          }
        });
        
        // If file opened successfully, show a message
        if (result.type == ResultType.done) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Opening ${widget.fileName} in ${_getFileTypeName(widget.type)}...',
              ),
              backgroundColor: AppTheme.accent,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isOpening = false;
          _errorMessage = 'Failed to open file: $e';
        });
      }
    }
  }
  
  String _getErrorMessage(OpenResult result) {
    switch (result.type) {
      case ResultType.noAppToOpen:
        return 'No app available to open ${widget.fileName}. Please install an app that can open ${_getFileTypeName(widget.type)} files.';
      case ResultType.fileNotFound:
        return 'File not found.';
      case ResultType.error:
        final message = result.message;
        return 'Error opening file: ${message.isNotEmpty ? message : "Unknown error"}';
      default:
        return 'Unable to open file.';
    }
  }
  
  String _getFileTypeName(DocumentType type) {
    switch (type) {
      case DocumentType.excel:
        return 'Excel';
      case DocumentType.word:
        return 'Word';
      case DocumentType.pages:
        return 'Pages';
      default:
        return 'document';
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.primary,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _getIconForType(widget.type),
              size: 64,
              color: AppTheme.accent,
            ),
            const SizedBox(height: 24),
            Text(
              widget.fileName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_isOpening)
              const Column(
                children: [
                  CircularProgressIndicator(color: AppTheme.accent),
                  SizedBox(height: 16),
                  Text(
                    'Opening file...',
                    style: TextStyle(color: AppTheme.text),
                  ),
                ],
              )
            else if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: AppTheme.warning,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: AppTheme.warning,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _openFile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: AppTheme.primary,
                      ),
                      child: const Text('Try Again'),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  Text(
                    'File opened in ${_getFileTypeName(widget.type)}',
                    style: TextStyle(
                      color: AppTheme.text.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _openFile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: AppTheme.primary,
                    ),
                    child: const Text('Open Again'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
  
  IconData _getIconForType(DocumentType type) {
    switch (type) {
      case DocumentType.excel:
        return Icons.table_chart;
      case DocumentType.word:
        return Icons.description;
      case DocumentType.pages:
        return Icons.article;
      default:
        return Icons.insert_drive_file;
    }
  }
}

/// Unknown file type viewer
class _UnknownFileViewer extends StatelessWidget {
  final File file;
  final String fileName;
  
  const _UnknownFileViewer({
    required this.file,
    required this.fileName,
  });
  
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.primary,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.insert_drive_file,
              size: 64,
              color: AppTheme.accent,
            ),
            const SizedBox(height: 24),
            Text(
              fileName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'This file type is not supported for preview.',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                try {
                  await OpenFilex.open(file.path);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to open file: $e'),
                        backgroundColor: AppTheme.warning,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.primary,
              ),
              child: const Text('Open with System App'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Document type enum
enum DocumentType {
  pdf,
  excel,
  word,
  pages,
  unknown,
}
