import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
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

    final items = _buildItems(library);
    if (items.isEmpty) {
      return;
    }

    debugPrint('🔎 Spotlight: indexing ${items.length} Otzaria sources');

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

    debugPrint('🔎 Spotlight: finished indexing ${items.length} Otzaria sources');
  }

  List<Map<String, Object?>> _buildItems(Library library) {
    final seenDeepLinks = <String>{};
    final items = <Map<String, Object?>>[];

    for (final book in library.getAllBooks()) {
      final id = book.id;
      if (id == null || id <= 0) {
        continue;
      }

      final title = book.title.trim();
      if (title.isEmpty) {
        continue;
      }

      final fileType = (book.fileType ?? '').toLowerCase();
      final isPdf = book is PdfBook || fileType == 'pdf';
      final deepLink = isPdf
          ? 'otzaria://open/pdf/$id'
          : 'otzaria://open/book/$id';

      // Avoid duplicate Spotlight items when the same source appears in multiple
      // catalog representations. The deep link is the canonical identity.
      if (!seenDeepLinks.add(deepLink)) {
        continue;
      }

      final path = _normalizeTreePath(
        book.categoryPath ?? book.heCategories ?? book.topics,
      );
      final author = book.author?.trim();
      final searchableTextParts = <String>[
        title,
        if (path.isNotEmpty) path,
        if (author != null && author.isNotEmpty) author,
        if (book.extraTitles != null) ...book.extraTitles!,
      ];

      items.add({
        'id': deepLink,
        'title': title,
        'subtitle': path,
        'author': author,
        'deepLink': deepLink,
        'kind': isPdf ? 'pdf' : 'book',
        'keywords': searchableTextParts
            .expand((part) => part
                .split(RegExp(r'[,/›>]+'))
                .map((piece) => piece.trim())
                .where((piece) => piece.isNotEmpty))
            .toSet()
            .toList(),
      });
    }

    return items;
  }

  String _normalizeTreePath(String? rawPath) {
    if (rawPath == null) return '';
    return rawPath
        .split(RegExp(r'[,/›>]+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != 'ספריית אוצריא')
        .join(' › ');
  }
}
