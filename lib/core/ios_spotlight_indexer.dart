import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:otzaria/core/error_log_file.dart';
import 'package:otzaria/data/data_providers/sqlite_data_provider.dart';
import 'package:otzaria/library/models/library.dart';
import 'package:otzaria/models/books.dart';

/// Sends Otzaria library-source metadata to the native iOS Core Spotlight index.
///
/// This intentionally indexes catalog metadata only — book/source title, tree path,
/// author and a deep link back into Otzaria — not the full text of every book.
class IOSSpotlightIndexer {
  static const MethodChannel _channel = MethodChannel('otzaria/spotlight');
  static const int _batchSize = 500;

  static final IOSSpotlightIndexer instance = IOSSpotlightIndexer._();

  IOSSpotlightIndexer._();

  Future<void> indexLibrary(Library library) async {
    if (kIsWeb || !Platform.isIOS) {
      return;
    }

    final flutterBooksCount = library.getAllBooks().length;
    var items = _buildItems(library);
    _appendDiagnosticLog(
      'Built ${items.length} Spotlight items from Flutter library catalog.',
      details: {
        'Flutter books': flutterBooksCount.toString(),
      },
    );

    if (items.isEmpty) {
      _appendDiagnosticLog(
        'Flutter library catalog yielded no Spotlight items; trying direct seforim.db fallback.',
      );
      items = await _buildItemsFromDatabaseCatalog();
    }

    if (items.isEmpty) {
      _appendDiagnosticLog(
        'No Spotlight items were built from Flutter library catalog or seforim.db.',
      );
      return;
    }

    debugPrint('🔎 Spotlight: indexing ${items.length} Otzaria sources');
    _appendDiagnosticLog(
      'Started indexing ${items.length} Otzaria sources.',
      details: {
        'First item': items.first['title']?.toString(),
        'First link': items.first['deepLink']?.toString(),
      },
    );

    try {
      var reset = true;
      for (var start = 0; start < items.length; start += _batchSize) {
        final end = start + _batchSize > items.length
            ? items.length
            : start + _batchSize;
        final batch = items.sublist(start, end);
        await _channel.invokeMethod<void>('indexBooks', {
          'reset': reset,
          'items': batch,
        });
        reset = false;
      }
    } catch (error, stackTrace) {
      _appendDiagnosticLog(
        'Spotlight indexing failed.',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }

    debugPrint('🔎 Spotlight: finished indexing ${items.length} Otzaria sources');
    _appendDiagnosticLog('Finished indexing ${items.length} Otzaria sources.');
  }

  List<Map<String, Object?>> _buildItems(Library library) {
    final seenDeepLinks = <String>{};
    final items = <Map<String, Object?>>[];

    for (final book in library.getAllBooks()) {
      final item = _buildItem(
        id: book.id,
        title: book.title,
        fileType: book.fileType,
        categoryPath: book.categoryPath ?? book.heCategories ?? book.topics,
        author: book.author,
        extraTitles: book.extraTitles,
        seenDeepLinks: seenDeepLinks,
      );
      if (item != null) {
        items.add(item);
      }
    }

    return items;
  }

  Future<List<Map<String, Object?>>> _buildItemsFromDatabaseCatalog() async {
    final sqliteProvider = SqliteDataProvider.instance;
    try {
      if (!sqliteProvider.isInitialized) {
        await sqliteProvider.initialize();
      }
      final repository = sqliteProvider.repository;
      if (repository == null) {
        _appendDiagnosticLog(
          'seforim.db fallback skipped: sqlite repository is not initialized.',
          details: {
            'DB path': sqliteProvider.dbPath,
            'DB exists': (await File(sqliteProvider.dbPath).exists()).toString(),
          },
        );
        return const [];
      }

      final db = await repository.database.database;
      final bookRows = repository.database.bookDao.getAllBooksMinimal(db);
      final categoryRows = repository.database.categoryDao.getAllCategoryRows(db);
      final authorsByBookId = repository.database.bookDao.getBookAuthorsMap(db);

      final categoryById = <int, Map<String, dynamic>>{};
      for (final row in categoryRows) {
        final id = row['id'];
        if (id is int) {
          categoryById[id] = Map<String, dynamic>.from(row);
        }
      }

      String categoryPathFor(int? categoryId) {
        if (categoryId == null) return '';
        final parts = <String>[];
        final seenPathIds = <int>{};
        var currentId = categoryId;
        while (seenPathIds.add(currentId)) {
          final row = categoryById[currentId];
          if (row == null) break;
          final title = row['title']?.toString().trim();
          if (title != null &&
              title.isNotEmpty &&
              title != 'ספריית אוצריא' &&
              title != 'אודות התוכנה') {
            parts.insert(0, title);
          }
          final parentId = row['parentId'];
          if (parentId is! int) break;
          currentId = parentId;
        }
        return parts.join(' › ');
      }

      final seenDeepLinks = <String>{};
      final items = <Map<String, Object?>>[];
      for (final rawRow in bookRows) {
        final row = Map<String, dynamic>.from(rawRow);
        final id = row['id'];
        final title = row['title']?.toString();
        if (id is! int || title == null || title.trim().isEmpty) {
          continue;
        }

        final categoryId = row['categoryId'] is int ? row['categoryId'] as int : null;
        final item = _buildItem(
          id: id,
          title: title,
          fileType: row['fileType']?.toString(),
          categoryPath: categoryPathFor(categoryId),
          author: authorsByBookId[id],
          extraTitles: null,
          seenDeepLinks: seenDeepLinks,
        );
        if (item != null) {
          items.add(item);
        }
      }

      _appendDiagnosticLog(
        'seforim.db fallback built ${items.length} Spotlight items.',
        details: {
          'DB path': sqliteProvider.dbPath,
          'DB books': bookRows.length.toString(),
          'DB categories': categoryRows.length.toString(),
          'First DB item': items.isEmpty ? null : items.first['title']?.toString(),
          'First DB link': items.isEmpty ? null : items.first['deepLink']?.toString(),
        },
      );
      return items;
    } catch (error, stackTrace) {
      _appendDiagnosticLog(
        'seforim.db fallback failed.',
        error: error,
        stackTrace: stackTrace,
        details: {
          'DB path': sqliteProvider.dbPath,
        },
      );
      return const [];
    }
  }

  Map<String, Object?>? _buildItem({
    required int? id,
    required String title,
    required String? fileType,
    required String? categoryPath,
    required String? author,
    required List<String>? extraTitles,
    required Set<String> seenDeepLinks,
  }) {
    if (id == null || id <= 0) {
      return null;
    }

    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      return null;
    }

    final normalizedFileType = (fileType ?? '').toLowerCase();
    final isPdf = normalizedFileType == 'pdf';
    final deepLink = isPdf
        ? 'otzaria://open/pdf/$id'
        : 'otzaria://open/book/$id';

    if (!seenDeepLinks.add(deepLink)) {
      return null;
    }

    final path = _normalizeTreePath(categoryPath);
    final normalizedAuthor = author?.trim();
    final searchableTextParts = <String>[
      normalizedTitle,
      if (path.isNotEmpty) path,
      if (normalizedAuthor != null && normalizedAuthor.isNotEmpty)
        normalizedAuthor,
      if (extraTitles != null) ...extraTitles,
    ];

    return {
      'id': deepLink,
      'title': normalizedTitle,
      'subtitle': path,
      'author': normalizedAuthor,
      'deepLink': deepLink,
      'kind': isPdf ? 'pdf' : 'book',
      'keywords': searchableTextParts
          .expand((part) => part
              .split(RegExp(r'[,/›>]+'))
              .map((piece) => piece.trim())
              .where((piece) => piece.isNotEmpty))
          .toSet()
          .toList(),
    };
  }

  String _normalizeTreePath(String? rawPath) {
    if (rawPath == null) return '';
    return rawPath
        .split(RegExp(r'[,/›>]+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != 'ספריית אוצריא')
        .join(' › ');
  }

  void _appendDiagnosticLog(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String?> details = const {},
  }) {
    try {
      ErrorLogFile.append(
        title: 'Spotlight Indexing',
        error: error ?? message,
        stackTrace: stackTrace,
        details: details,
      );
    } catch (_) {
      // Diagnostics must never affect app startup or library loading.
    }
  }
}
