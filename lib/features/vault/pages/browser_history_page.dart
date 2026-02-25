import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/services/browser_session_service.dart';

/// Dedicated page for browsing history
class BrowserHistoryPage extends StatefulWidget {
  const BrowserHistoryPage({super.key});

  @override
  State<BrowserHistoryPage> createState() => _BrowserHistoryPageState();
}

class _BrowserHistoryPageState extends State<BrowserHistoryPage> {
  final TextEditingController _searchController = TextEditingController();
  List<BrowserHistoryEntry> _filteredHistory = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadHistory();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _loadHistory() {
    final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
    setState(() {
      _filteredHistory = List.from(sessionService.history);
    });
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
    
    setState(() {
      if (query.isEmpty) {
        _filteredHistory = List.from(sessionService.history);
        _isSearching = false;
      } else {
        _isSearching = true;
        _filteredHistory = sessionService.history.where((entry) {
          return entry.title.toLowerCase().contains(query) ||
                 entry.url.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes == 0) {
          return 'Just now';
        }
        return '${difference.inMinutes}m ago';
      }
      return '${difference.inHours}h ago';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      appBar: AppBar(
        title: const Text('History'),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: AppTheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                  ),
                  title: const Text(
                    'Clear History',
                    style: TextStyle(color: AppTheme.text),
                  ),
                  content: const Text(
                    'Are you sure you want to clear all browsing history?',
                    style: TextStyle(color: AppTheme.text),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                final sessionService = Provider.of<BrowserSessionService>(context, listen: false);
                await sessionService.clearHistory();
                if (mounted) {
                  _loadHistory();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('History cleared')),
                  );
                }
              }
            },
            tooltip: 'Clear History',
          ),
        ],
      ),
      body: Consumer<BrowserSessionService>(
        builder: (context, sessionService, _) {
          if (_filteredHistory.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.history,
                    size: 64,
                    color: AppTheme.text.withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isSearching ? 'No results found' : 'No history',
                    style: TextStyle(
                      fontSize: 18,
                      color: AppTheme.text.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              // Search bar
              Container(
                padding: const EdgeInsets.all(16),
                color: AppTheme.surface,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search history...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppTheme.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              // History list
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _filteredHistory.length,
                  itemBuilder: (context, index) {
                    final entry = _filteredHistory[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: AppTheme.surfaceVariant,
                      child: ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.history,
                            color: AppTheme.accent,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          entry.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              entry.url,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.text.withOpacity(0.7),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _formatTimestamp(entry.timestamp),
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.text.withOpacity(0.5),
                              ),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.open_in_new, size: 20),
                          onPressed: () {
                            Navigator.pop(context, entry.url);
                          },
                          tooltip: 'Open',
                        ),
                        onTap: () {
                          Navigator.pop(context, entry.url);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
