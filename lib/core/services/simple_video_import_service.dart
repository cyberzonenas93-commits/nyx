import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/vault_item.dart';
import 'vault_service.dart';

/// SharedPreferences key for "always delete originals, don't ask again".
///
/// Defaults to **false**: after each import the user is asked whether to remove
/// the originals from Photos. Ticking "always delete" in that prompt sets this,
/// and Settings → Storage can turn it back off.
///
/// Only an affirmative choice is ever remembered — there is deliberately no
/// stored "always keep", so a destructive action never becomes silent in either
/// direction without the user opting in.
///
/// Note [SimpleVideoImportService.removeOriginals] still defaults to `false`:
/// deletion must be an explicit decision at every call site.
const String kAlwaysDeleteOriginalsKey = 'vault_always_delete_originals';

typedef OriginalVideoDeleter = Future<List<String>> Function(
  List<String> assetIds,
);
typedef VideoSourceLoader = Future<SimpleVideoImportSource> Function();

class SimpleVideoImportRequest {
  final String assetId;
  final VideoSourceLoader loadSource;

  const SimpleVideoImportRequest({
    required this.assetId,
    required this.loadSource,
  });
}

class SimpleVideoImportSource {
  final File file;
  final String filename;
  final String? mimeType;
  final String? folderId;
  final int timestampMs;
  final int? width;
  final int? height;
  final int? durationMs;

  const SimpleVideoImportSource({
    required this.file,
    required this.filename,
    required this.timestampMs,
    this.mimeType,
    this.folderId,
    this.width,
    this.height,
    this.durationMs,
  });
}

class SimpleVideoImportFailure {
  final String assetId;
  final Object error;

  const SimpleVideoImportFailure({
    required this.assetId,
    required this.error,
  });
}

/// Cooperative cancellation for an in-flight import batch.
///
/// Cancellation is checked between items, never mid-file: a partially written
/// payload must never be left behind, and an item that has already committed
/// its index row stays committed.
class ImportCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class SimpleVideoImportResult {
  final List<VaultItem> storedItems;
  final List<SimpleVideoImportFailure> failures;
  final Set<String> deletedAssetIds;
  final Object? deletionError;

  /// True when the batch stopped early because the user cancelled.
  final bool wasCancelled;

  /// Requests never attempted because of cancellation.
  final int skippedCount;

  const SimpleVideoImportResult({
    required this.storedItems,
    required this.failures,
    required this.deletedAssetIds,
    this.deletionError,
    this.wasCancelled = false,
    this.skippedCount = 0,
  });

  int get storedCount => storedItems.length;
  int get failedCount => failures.length;
  int get deletedCount => deletedAssetIds.length;
  int get retainedOriginalCount => storedCount - deletedCount;
}

/// Deliberately small video-import transaction:
///
/// 1. Stream/encrypt one prepared Photos file into the vault.
/// 2. Atomically persist its index row.
/// 3. After all successful commits, delete only those Photos asset IDs.
///
/// No deduplication, thumbnail extraction, metadata decoding, or background
/// import queue runs on this path. Eligible iCloud backup is scheduled only
/// after the local batch and Photos deletion finish, so it cannot slow or
/// overlap the critical import work.
class SimpleVideoImportService {
  final VaultService _vaultService;

  const SimpleVideoImportService(this._vaultService);

  /// Imports [requests] into the vault.
  ///
  /// Originals are deleted from Photos only when [removeOriginals] is true —
  /// the caller's explicit, user-controlled choice. Deletion never happens for
  /// an item that failed to commit.
  Future<SimpleVideoImportResult> importAndDelete({
    required List<SimpleVideoImportRequest> requests,
    required OriginalVideoDeleter deleteOriginals,
    void Function(int current, int total, String status)? onProgress,
    ImportCancellationToken? cancellationToken,
    bool removeOriginals = false,
  }) async {
    final storedItems = <VaultItem>[];
    final failures = <SimpleVideoImportFailure>[];
    final committedAssetIds = <String>[];
    var cancelledAt = -1;

    for (var index = 0; index < requests.length; index++) {
      // Checked between items only, so a payload is never left half-written.
      if (cancellationToken?.isCancelled ?? false) {
        cancelledAt = index;
        debugPrint(
            '[SimpleVideoImport] Cancelled after $index of ${requests.length}');
        break;
      }
      final request = requests[index];
      // Report items *completed* (index), not the 1-based ordinal of the item
      // about to start. Reporting index+1 up front pinned a single-video import
      // at 100% for the whole encryption pass, which looked like a hang.
      onProgress?.call(
        index,
        requests.length,
        'Storing ${index + 1} of ${requests.length}',
      );

      try {
        // If a prior run committed the item but crashed before Photos deletion,
        // finish the deletion without creating a duplicate vault item.
        final existing = _findItemForAsset(request.assetId);
        if (existing != null) {
          storedItems.add(existing);
          committedAssetIds.add(request.assetId);
          continue;
        }

        final source = await request.loadSource();
        final metadata = <String, dynamic>{
          'timestampMs': source.timestampMs,
          'sourceAssetId': request.assetId,
          if (source.width != null) 'width': source.width,
          if (source.height != null) 'height': source.height,
          if (source.durationMs != null) 'durationMs': source.durationMs,
        };
        final item = await _vaultService.storeFileFromPath(
          sourceFilePath: source.file.path,
          filename: source.filename,
          mimeType: source.mimeType,
          source: VaultItemSource.import,
          folderId: source.folderId,
          metadata: metadata,
          queueThumbnailGeneration: false,
          deduplicate: false,
          queueICloudBackup: false,
          persistImmediately: true,
        );
        storedItems.add(item);
        committedAssetIds.add(request.assetId);
      } catch (error, stackTrace) {
        // Failures used to be counted and nothing else, which made a failed
        // video import impossible to diagnose from a device log.
        debugPrint(
            '[SimpleVideoImport] Failed to import asset ${request.assetId}: $error');
        debugPrint('[SimpleVideoImport] $stackTrace');
        failures.add(
          SimpleVideoImportFailure(assetId: request.assetId, error: error),
        );
      }
    }

    var deletedAssetIds = <String>{};
    Object? deletionError;
    if (removeOriginals && committedAssetIds.isNotEmpty) {
      onProgress?.call(
        requests.length,
        requests.length,
        'Deleting stored originals',
      );
      try {
        final deleted = await deleteOriginals(committedAssetIds);
        final committedSet = committedAssetIds.toSet();
        deletedAssetIds = deleted.where(committedSet.contains).toSet();
      } catch (error) {
        // The vault commits remain valid. Report that originals were retained;
        // never retry storage or roll back safe copies because deletion failed.
        deletionError = error;
      }
    }

    // Keep the import transaction local and sequential. Once it is complete,
    // hand committed ciphertext payloads to VaultService's non-blocking iCloud
    // queue. VaultService applies the user's platform/storage eligibility.
    if (storedItems.isNotEmpty) {
      _vaultService.queueICloudBackupForItems(
        storedItems.map((item) => item.id),
      );
    }

    return SimpleVideoImportResult(
      storedItems: storedItems,
      failures: failures,
      deletedAssetIds: deletedAssetIds,
      deletionError: deletionError,
      wasCancelled: cancelledAt >= 0,
      skippedCount: cancelledAt >= 0 ? requests.length - cancelledAt : 0,
    );
  }

  VaultItem? _findItemForAsset(String assetId) {
    for (final item in _vaultService.items) {
      if (item.metadata?['sourceAssetId'] == assetId) return item;
    }
    return null;
  }
}
