import 'package:flutter/material.dart';
import 'package:otzaria/settings/tabs/spotlight_settings_tab.dart';
import 'package:otzaria/settings/tabs/system_settings_tab.dart' as original;

class SystemSettingsTab extends StatelessWidget {
  const SystemSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: const TabBar(
              tabs: [
                Tab(text: 'מערכת'),
                Tab(text: 'Spotlight'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                original.SystemSettingsTab(),
                SpotlightSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
