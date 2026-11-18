import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../utils/route_transitions.dart';
import '../widgets/app_bar.dart';
import '../widgets/quick_switch_bar.dart';
import 'channels_screen.dart';
import 'contacts_screen.dart';
import 'map_screen.dart';

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen>
    with DisconnectNavigationMixin {
  static const double _dividerWidth = 24;
  static const double _minPaneFraction = 0.15;
  static const double _maxPaneFraction = 0.85;

  double _splitFraction = 0.5;

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    if (!checkConnectionAndNavigate(connector)) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(context.l10n.nav_tasks),
        automaticallyImplyLeading: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dividerWidth = constraints.maxWidth < _dividerWidth
              ? constraints.maxWidth
              : _dividerWidth;
          final availableWidth = constraints.maxWidth - dividerWidth;
          final leftWidth = availableWidth * _splitFraction;

          return Row(
            children: [
              SizedBox(
                key: const Key('tasks-left-section'),
                width: leftWidth,
                child: const SizedBox.expand(),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    if (availableWidth <= 0) return;
                    setState(() {
                      _splitFraction =
                          (_splitFraction + details.delta.dx / availableWidth)
                              .clamp(_minPaneFraction, _maxPaneFraction);
                    });
                  },
                  child: SizedBox(
                    key: const Key('tasks-splitter'),
                    width: dividerWidth,
                    child: Center(
                      child: Container(
                        width: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
              const Expanded(
                child: SizedBox.expand(key: Key('tasks-right-section')),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: QuickSwitchBar(
          selectedIndex: 3,
          onDestinationSelected: (index) {
            switch (index) {
              case 0:
                Navigator.pushReplacement(
                  context,
                  buildQuickSwitchRoute(
                    const ContactsScreen(hideBackButton: true),
                  ),
                );
                break;
              case 1:
                Navigator.pushReplacement(
                  context,
                  buildQuickSwitchRoute(
                    const ChannelsScreen(hideBackButton: true),
                  ),
                );
                break;
              case 2:
                Navigator.pushReplacement(
                  context,
                  buildQuickSwitchRoute(const MapScreen(hideBackButton: true)),
                );
                break;
            }
          },
          contactsUnreadCount: connector.getTotalContactsUnreadCount(),
          channelsUnreadCount: connector.getTotalChannelsUnreadCount(),
        ),
      ),
    );
  }
}
