import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otzaria/core/ios_spotlight_indexer.dart';
import 'package:otzaria/core/ui_snack.dart';
import 'package:otzaria/data/repository/data_repository.dart';
import 'package:otzaria/settings/widgets/settings_card.dart';
import 'package:otzaria/theme/theme_exports.dart';
import 'package:otzaria/widgets/dialogs/app_dialogs.dart';
import 'package:otzaria/widgets/widgets_exports.dart';

class SpotlightSettingsTab extends StatefulWidget {
  const SpotlightSettingsTab({super.key});

  @override
  State<SpotlightSettingsTab> createState() => _SpotlightSettingsTabState();
}

class _SpotlightSettingsTabState extends State<SpotlightSettingsTab> {
  static const MethodChannel _spotlightChannel = MethodChannel('otzaria/spotlight');

  final TextEditingController _searchController = TextEditingController();
  List<_SpotlightUiItem> _items = const [];
  String _status = 'ממתין לטעינה';
  String? _lastError;
  DateTime? _lastStartedAt;
  DateTime? _lastFinishedAt;
  bool _isLoading = true;
  bool _isWorking = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadCurrentLibraryItems();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentLibraryItems() async {
    if (!Platform.isIOS) {
      setState(() {
        _isLoading = false;
        _status = 'Spotlight זמין רק ב-iOS';
        _items = const [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _status = 'טוען ספרייה';
      _lastError = null;
    });

    try {
      final library = await DataRepository.instance.library;
      final seen = <String>{};
      final items = <_SpotlightUiItem>[];
      for (final book in library.getAllBooks()) {
        final id = book.id;
        final title = book.title.trim();
        if (id == null || id <= 0 || title.isEmpty) continue;

        final fileType = (book.fileType ?? '').toLowerCase();
        final isPdf = fileType == 'pdf';
        final deepLink = isPdf
            ? 'otzaria://open/pdf/$id'
            : 'otzaria://open/book/$id';
        if (!seen.add(deepLink)) continue;

        items.add(_SpotlightUiItem(
          title: title,
          subtitle: _normalizeTreePath(book.categoryPath ?? book.heCategories ?? book.topics),
          author: book.author?.trim() ?? '',
          deepLink: deepLink,
          kind: isPdf ? 'pdf' : 'book',
        ));
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _isLoading = false;
        _status = items.isEmpty
            ? 'לא נמצאו פריטים זמינים לאינדוקס'
            : 'מוכן לאינדוקס — ${items.length} פריטים';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _lastError = error.toString();
        _status = 'טעינת הפריטים נכשלה';
      });
    }
  }

  Future<void> _rebuildIndex() async {
    if (!Platform.isIOS || _isWorking) return;
    setState(() {
      _isWorking = true;
      _status = 'בונה אינדקס Spotlight';
      _lastStartedAt = DateTime.now();
      _lastFinishedAt = null;
      _lastError = null;
    });

    try {
      final library = await DataRepository.instance.library;
      await IOSSpotlightIndexer.instance.indexLibrary(library);
      if (!mounted) return;
      setState(() {
        _status = 'האינדקס נבנה בהצלחה';
        _lastFinishedAt = DateTime.now();
      });
      UiSnack.showSuccess('אינדקס Spotlight נבנה בהצלחה.');
      await _loadCurrentLibraryItems();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastError = error.toString();
        _status = 'בניית האינדקס נכשלה';
        _lastFinishedAt = DateTime.now();
      });
      UiSnack.showError('שגיאה בבניית אינדקס Spotlight: $error');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _clearIndex() async {
    if (!Platform.isIOS || _isWorking) return;
    final confirmed = await showWarningDialog(
      context: context,
      title: 'למחוק את אינדקס Spotlight?',
      content: 'כל תוצאות Spotlight של אוצריא יימחקו מהמכשיר. ניתן לבנות את האינדקס מחדש בכל רגע.',
      confirmText: 'מחק אינדקס',
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _isWorking = true;
      _status = 'מוחק אינדקס Spotlight';
      _lastStartedAt = DateTime.now();
      _lastFinishedAt = null;
      _lastError = null;
    });

    try {
      await _spotlightChannel.invokeMethod<void>('indexBooks', {
        'reset': true,
        'items': const <Map<String, Object?>>[],
      });
      if (!mounted) return;
      setState(() {
        _status = 'אינדקס Spotlight נמחק';
        _lastFinishedAt = DateTime.now();
      });
      UiSnack.show('אינדקס Spotlight נמחק.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastError = error.toString();
        _status = 'מחיקת האינדקס נכשלה';
        _lastFinishedAt = DateTime.now();
      });
      UiSnack.showError('שגיאה במחיקת אינדקס Spotlight: $error');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  List<_SpotlightUiItem> get _filteredItems {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _items;
    return _items.where((item) => item.matches(query)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredItems = _filteredItems;

    return SingleChildScrollView(
      primary: true,
      padding: const EdgeInsets.all(16),
      child: ToolPanelWrapper(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsCard(
              title: 'אינדקס Spotlight',
              subtitle: 'ניהול האינדקס שמוצג בחיפוש של iOS',
              children: [
                ListTile(
                  leading: _isWorking || _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.manage_search),
                  title: Text(_status, style: AppTextStyles.settingTitle),
                  subtitle: Text(_buildStatusSubtitle(), style: AppTextStyles.settingSubtitle),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _isWorking || _isLoading || !Platform.isIOS ? null : _rebuildIndex,
                        icon: const Icon(Icons.refresh),
                        label: const Text('צור / בנה מחדש אינדקס'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isWorking || !Platform.isIOS ? null : _clearIndex,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('מחק אינדקס'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isWorking ? null : _loadCurrentLibraryItems,
                        icon: const Icon(Icons.sync),
                        label: const Text('רענן רשימה'),
                      ),
                    ],
                  ),
                ),
                if (_lastError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      _lastError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
              ],
            ),
            kSettingsCardSpacing,
            SettingsCard(
              title: 'פריטים לאינדוקס',
              subtitle: '${filteredItems.length} מתוך ${_items.length} פריטים',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'חיפוש בפריטי Spotlight',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                SizedBox(
                  height: 520,
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : filteredItems.isEmpty
                          ? Center(
                              child: Text(
                                _items.isEmpty ? 'אין פריטים להצגה' : 'לא נמצאו תוצאות לחיפוש',
                              ),
                            )
                          : ListView.separated(
                              primary: false,
                              itemCount: filteredItems.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final item = filteredItems[index];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(item.kind == 'pdf'
                                      ? Icons.picture_as_pdf_outlined
                                      : Icons.menu_book_outlined),
                                  title: Text(item.title),
                                  subtitle: Text([
                                    if (item.subtitle.isNotEmpty) item.subtitle,
                                    if (item.author.isNotEmpty) 'מחבר: ${item.author}',
                                    item.deepLink,
                                  ].join('\n')),
                                  isThreeLine: true,
                                );
                              },
                            ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _buildStatusSubtitle() {
    final parts = <String>[
      'פריטים זמינים: ${_items.length}',
      if (_lastStartedAt != null) 'התחלה: ${_formatTime(_lastStartedAt!)}',
      if (_lastFinishedAt != null) 'סיום: ${_formatTime(_lastFinishedAt!)}',
    ];
    return parts.join(' · ');
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
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

class _SpotlightUiItem {
  final String title;
  final String subtitle;
  final String author;
  final String deepLink;
  final String kind;

  const _SpotlightUiItem({
    required this.title,
    required this.subtitle,
    required this.author,
    required this.deepLink,
    required this.kind,
  });

  bool matches(String query) {
    return title.toLowerCase().contains(query) ||
        subtitle.toLowerCase().contains(query) ||
        author.toLowerCase().contains(query) ||
        deepLink.toLowerCase().contains(query) ||
        kind.toLowerCase().contains(query);
  }
}
