import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:otzaria/core/ios_spotlight_indexer.dart';
import 'package:otzaria/data/cache/acronyms_cache.dart';
import 'package:otzaria/data/cache/generation_cache.dart';
import 'package:otzaria/data/data_providers/file_system_data_provider.dart';
import 'package:otzaria/indexing/bloc/indexing_bloc.dart';
import 'package:otzaria/indexing/bloc/indexing_event.dart';
import 'package:otzaria/models/books.dart';
import 'package:otzaria/library/models/library.dart';
import 'package:otzaria/utils/text/text_manipulation.dart';

/// DataRepository acts as a centralized data access layer that coordinates between different
/// data providers (file system, Hive storage, and Tantivy search engine).
///
/// This repository implements the Repository pattern to abstract the data source
/// implementation details from the business logic. It provides a clean API for
/// accessing and manipulating application data from various sources.
class DataRepository {
  /// Handles file system operations like reading book texts and metadata
  final FileSystemData _fileSystemData = FileSystemData.instance;

  /// Singleton instance of the DataRepository
  static final DataRepository _singleton = DataRepository();

  /// Provides access to the singleton instance
  static DataRepository get instance => _singleton;

  Future<Library>? _libraryFuture;
  Future<Library> get library => _libraryFuture ??= _getLibrary();
  set library(Future<Library> value) => _libraryFuture = value;

  // Lazy-loaded: only fetched when user actually searches for external books.
  // Previously these ran getAllBooksWithRelations() eagerly at startup,
  // competing with library loading for DB I/O.
  Future<List<Book>>? _hebrewBooksFuture;
  Future<List<Book>>? _localHebrewBooksFuture;
  Future<List<ExternalLibraryBook>>? _otzarBooksFuture;
  Future<List<Book>> get hebrewBooks => _hebrewBooksFuture ??= getHebrewBooks();

  /// ספרי היברובוקס שקיים להם PDF מקומי (כ-[PdfBook]). נחשבים מקומיים
  /// ומוצגים בחיפוש גם כשהצגת ספרים חיצוניים כבויה.
  Future<List<Book>> get localHebrewBooks =>
      _localHebrewBooksFuture ??= FileSystemData.getLocalHebrewBooks();
  Future<List<ExternalLibraryBook>> get otzarBooks =>
      _otzarBooksFuture ??= getOtzarBooks();

  /// Invalidates cached external books so they are re-fetched on next access.
  /// Call this when the library is refreshed.
  void invalidateExternalBooksCache() {
    _hebrewBooksFuture = null;
    _localHebrewBooksFuture = null;
    _otzarBooksFuture = null;
  }

  DataRepository();

  /// Retrieves the complete library metadata including all available books
  ///
  /// Returns a [Future] that completes with a [Library] object containing
  /// the full library structure and metadata
  Future<Library> _getLibrary() async {
    final library = await _fileSystemData.getLibrary();
    unawaited(
      IOSSpotlightIndexer.instance.indexLibrary(library).catchError(
        (Object error) {
          debugPrint('Spotlight indexing failed: $error');
        },
      ),
    );
    return library;
  }

  /// Retrieves the list of books from the Otzar HaHochma project
  ///
  /// Returns a [Future] that completes with a list of [ExternalLibraryBook] objects
  /// representing books from the Otzar HaHochma collection
  Future<List<ExternalLibraryBook>> getOtzarBooks() {
    return FileSystemData.getOtzarBooks();
  }

  /// Retrieves the list of books from the Hebrew Books project
  ///
  /// Returns a [Future] that completes with a list of [Book] objects
  /// representing books from the Hebrew Books collection
  Future<List<Book>> getHebrewBooks() {
    return FileSystemData.getHebrewBooks();
  }

  /// Retrieves the full text content of a specific book
  ///
  /// Parameters:
  ///   - [title]: The title of the book to retrieve
  ///
  /// Returns a [Future] that completes with the book's text content as a [String]
  Future<String> getBookText(String title,
      {int? categoryId, String? fileType}) async {
    return _fileSystemData.getBookText(title,
        categoryId: categoryId, fileType: fileType);
  }

  /// Retrieves the table of contents for a specific book
  ///
  /// Parameters:
  ///   - [title]: The title of the book whose TOC should be retrieved
  ///
  /// Returns a [Future] that completes with a list of [TocEntry] objects
  /// representing the book's table of contents structure
  Future<List<TocEntry>> getBookToc(String title,
      {int? categoryId, String? fileType}) async {
    return _fileSystemData.getBookToc(title,
        categoryId: categoryId, fileType: fileType);
  }

  /// Searches for references by relevance to a given reference string
  ///
  /// Parameters:
  ///   - [ref]: The reference string to search for
  ///   - [limit]: Maximum number of results to return (defaults to 10)
  ///
  /// Returns a [Future] that completes with a list of [Ref] objects sorted by relevance

  /// Adds text content from the library to the Tantivy search index
  ///
  /// Parameters:
  ///   - [library]: The library containing books to index
  ///
  /// This method now uses the IndexingBloc to handle the indexing process
  Future<void> addAllTextsToTantivy(
    Library library,
  ) async {
    // Create an instance of IndexingBloc
    final indexingBloc = IndexingBloc.create();

    // Start the indexing process
    indexingBloc.add(StartIndexing(library));
  }

  /// Searches for books based on query text and optional filters
  ///
  /// Parameters:
  ///   - [query]: The search text to match against book titles
  ///   - [category]: Optional category to filter results
  ///   - [topics]: Optional list of topics to filter results
  ///   - [includeOtzar]: Whether to include Otzar HaChochma books
  ///   - [includeHebrewBooks]: Whether to include HebrewBooks.org books
  ///
  /// Returns a [Future] that completes with a list of [Book] objects matching the criteria
  Future<List<Book>> findBooks(
    String query,
    Category? category, {
    List<String>? topics,
    bool includeOtzar = false,
    bool includeHebrewBooks = false,
    bool sortByRatio = true,
  }) async {
    final normalizedQuery = _normalizeForSearch(query);
    final queryWords = normalizedQuery
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (queryWords.isEmpty) {
      return [];
    }

    final allBooks = <Book>[
      ...(category?.getAllBooks() ?? (await library).getAllBooks()),
    ];

    if (includeOtzar) {
      allBooks.addAll(await otzarBooks);
    }
    if (includeHebrewBooks) {
      allBooks.addAll(await hebrewBooks);
    } else {
      // ספרי היברובוקס שיש להם PDF מקומי הם ספרים שכבר נמצאים במחשב,
      // ולכן מוצגים תמיד — גם כשהצגת ספרים חיצוניים כבויה.
      allBooks.addAll(await localHebrewBooks);
    }

    // no-op אם הקאשים כבר חוממו בעליית האפליקציה
    await AcronymsCache.instance.warmUp();
    await GenerationCache.instance.warmUp();

    final searchEntries = <BookSearchEntry>[
      for (var i = 0; i < allBooks.length; i++)
        buildBookSearchEntry(
          i,
          allBooks[i],
          acronymsForId: AcronymsCache.instance.getAcronymsForBook,
          eraOrderForId: GenerationCache.instance.getOrderForBook,
        ),
    ];

    final matchingIndices = await Isolate.run(
      () => filterBookSearchEntries(
        entries: searchEntries,
        queryWords: queryWords,
        topics: topics ?? const <String>[],
        sortByRatio: sortByRatio,
        normalizedQuery: normalizedQuery,
      ),
    );

    return [
      for (final index in matchingIndices) allBooks[index],
    ];
  }

  String _normalizeForSearch(String input) {
    var cleaned = removeTeamim(removeVolwels(input));
    cleaned = cleaned.replaceAll('"', '').replaceAll("'", '');
    cleaned = cleaned.replaceAll('\u05F4', '').replaceAll('\u05F3', '');
    cleaned = cleaned.replaceAll(RegExp(r'[^a-zA-Z0-9\u0590-\u05FF\s]'), ' ');
    return cleaned.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

/// בונה [BookSearchEntry] לספר בודד. ה-lookups מוזרקים כדי לאפשר בדיקה
/// בלי DB. עבור ספר אישי מדלגים על כינויים ודור — ל-id שלו אין משמעות
/// במאגרים הרשמיים (מרחבי id נפרדים), אחרת הוא יורש נתון של ספר רשמי זר.
@visibleForTesting
BookSearchEntry buildBookSearchEntry(
  int index,
  Book book, {
  required List<String>? Function(int bookId) acronymsForId,
  required int Function(int? bookId) eraOrderForId,
}) {
  final id = book.id;
  return BookSearchEntry(
    index: index,
    title: book.title,
    author: book.author ?? '',
    topics: book.topics,
    acronyms: id == null || book.isUserBook
        ? const []
        : acronymsForId(id) ?? const [],
    eraOrder: eraOrderForId(book.isUserBook ? null : id),
    isUserBook: book.isUserBook,
  );
}

@visibleForTesting
class BookSearchEntry {
  final int index;
  final String title;
  final String author;
  final String topics;

  /// כינויים מנורמלים מראש מטבלת book_acronym (ראה [AcronymsCache]).
  final List<String> acronyms;

  /// סדר הדור של הספר (נמוך = מוקדם). ראה [GenerationCache]; ברירת מחדל = סוף.
  final int eraOrder;

  /// ספר אישי של המשתמש — תמיד אחרון בתוך תת-המיון של הדורות.
  final bool isUserBook;

  const BookSearchEntry({
    required this.index,
    required this.title,
    required this.author,
    required this.topics,
    this.acronyms = const [],
    this.eraOrder = 5,
    this.isUserBook = false,
  });
}
