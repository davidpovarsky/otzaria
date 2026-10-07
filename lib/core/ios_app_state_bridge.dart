import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:otzaria/navigation/bloc/navigation_bloc.dart';
import 'package:otzaria/navigation/bloc/navigation_state.dart';
import 'package:otzaria/tabs/bloc/tabs_bloc.dart';
import 'package:otzaria/tabs/bloc/tabs_state.dart';

class IOSAppStateBridge extends StatefulWidget {
  final Widget child;

  const IOSAppStateBridge({super.key, required this.child});

  @override
  State<IOSAppStateBridge> createState() => _IOSAppStateBridgeState();
}

class _IOSAppStateBridgeState extends State<IOSAppStateBridge> {
  static const MethodChannel _channel = MethodChannel('otzaria/app_state');
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _schedulePublish();
  }

  void _schedulePublish() {
    if (kIsWeb || !Platform.isIOS || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_publish());
    });
  }

  Future<void> _publish() async {
    try {
      final nav = context.read<NavigationBloc>().state;
      final tabs = context.read<TabsBloc>().state;
      final currentTab = tabs.currentTab;
      await _channel.invokeMethod<void>('updateSnapshot', {
        'updatedAt': DateTime.now().toIso8601String(),
        'currentScreen': nav.currentScreen.name,
        'currentScreenLabel': _screenLabel(nav.currentScreen),
        'hasOpenTabs': tabs.hasOpenTabs,
        'openTabsCount': tabs.tabs.length,
        'currentTabIndex': tabs.hasOpenTabs ? tabs.currentTabIndex : null,
        'currentTabTitle': currentTab?.title,
        'openTabsTitles': tabs.tabs.map((tab) => tab.title).toList(),
      });
    } catch (_) {}
  }

  String _screenLabel(Screen screen) {
    return switch (screen) {
      Screen.library => 'ספרייה',
      Screen.find => 'איתור',
      Screen.reading => 'עיון',
      Screen.search => 'חיפוש',
      Screen.more => 'כלים',
      Screen.settings => 'הגדרות',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isIOS) return widget.child;
    return MultiBlocListener(
      listeners: [
        BlocListener<NavigationBloc, NavigationState>(
          listener: (_, __) => _schedulePublish(),
        ),
        BlocListener<TabsBloc, TabsState>(
          listener: (_, __) => _schedulePublish(),
        ),
      ],
      child: widget.child,
    );
  }
}
