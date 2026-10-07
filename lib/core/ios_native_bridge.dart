import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:otzaria/data/repository/data_repository.dart';
import 'package:otzaria/models/books.dart';
import 'package:otzaria/search/models/search_configuration.dart';
import 'package:otzaria/search/search_query_builder.dart';
import 'package:otzaria/search/search_repository.dart';
import 'package:otzaria/utils/text/text_manipulation.dart' as utils;
import 'package:otzaria_search_engine/otzaria_search_engine.dart';

class IOSNativeBridge extends StatefulWidget {
  final Widget child;

  const IOSNativeBridge({super.key, required this.child});

  @override
  State<IOSNativeBridge> createState() => _IOSNativeBridgeState();
}

class _IOSNativeBridgeState extends State<IOSNativeBridge> {
  static const MethodChannel _channel = MethodChannel('otzaria/app_state');

  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isIOS) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_drain());
      });
      unawaited(_drain());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _drain() async {
    if (_busy || kIsWeb || !Platform.isIOS) return;
    _busy = true;
    try {
      final items = await _channel.invokeMethod<List<dynamic>>('drainShortcutSearches') ?? const <dynamic>[];
      for (final item in items) {
        if (item is Map) {
          await _runSearch(Map<String, dynamic>.from(item));
        }
      }
    } catch (_) {
      // Native side may not be ready during startup.
    } finally {
      _busy = false;
    }
  }

  Future<void> _runSearch(Map<String, dynamic> item) async {
    final id = item['id']?.toString();
    if (id == null || id.isEmpty) return;
    try {
      final query = item['query']?.toString() ?? '';
      final rawLimit = item['limit'];
      final limit = rawLimit is num ? rawLimit.toInt() : 10;
      final rows = await _searchText(query, limit: limit);
      await _channel.invokeMethod<void>('finishShortcutSearch', {
        'id': id,
        'result': jsonEncode({'ok': true, 'query': query, 'count': rows.length, 'results': rows}),
      });
    } catch (e) {
      await _channel.invokeMethod<void>('finishShortcutSearch', {
        'id': id,
        'result': jsonEncode({'ok': false, 'error': e.toString(), 'results': const []}),
      });
    }
  }

  Future<List<Map<String, Object?>>> _searchText(String query, {required int limit}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final normalizedLimit = math.min(math.max(limit, 1), 50);
    final repository = const SearchRepository();
    final results = await repository.searchTexts(
      SearchQueryBuilder.sanitizeQuery(trimmed),
      const ['/'],
      normalizedLimit,
      order: ResultsOrder.catalogue,
      searchMode: SearchMode.advanced,
    );

    final library = await DataRepository.instance.library;
    final books = library.getAllBooks();

    return results.map((result) {
      final segment = result.segment.toInt();
      final book = _findBook(result, books);
      final snippetHtml = result.text;
      return <String, Object?>{
        'title': result.title,
        'reference': result.reference,
        'snippetText': utils.stripHtmlIfNeeded(snippetHtml),
        'snippetHtml': snippetHtml,
        'segment': segment,
        'isPdf': result.isPdf,
        'filePath': result.filePath,
        'bookId': book?.id,
        'deepLink': _deepLink(result, book: book, segment: segment),
      };
    }).toList();
  }

  Book? _findBook(SearchResult result, List<Book> books) {
    for (final book in books) {
      if (result.isPdf && book is! PdfBook) continue;
      if (!result.isPdf && book is! TextBook) continue;
      if (book.filePath != null && book.filePath == result.filePath) return book;
      if (book.title == result.title) return book;
    }
    return null;
  }

  String? _deepLink(SearchResult result, {required Book? book, required int segment}) {
    final bookId = book?.id;
    if (bookId == null) return null;
    if (result.isPdf) {
      return 'otzaria://open/pdf/$bookId?index=${segment + 1}';
    }
    return 'otzaria://open/book/$bookId?index=$segment';
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
