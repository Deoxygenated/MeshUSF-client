import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshusf/connector/meshcore_connector.dart';
import 'package:meshusf/l10n/app_localizations.dart';
import 'package:meshusf/screens/tasks_screen.dart';

class _ConnectedMeshCoreConnector extends MeshCoreConnector {
  @override
  bool get isConnected => true;
}

void main() {
  testWidgets('Tasks screen has two resizable side-by-side sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final connector = _ConnectedMeshCoreConnector();
    addTearDown(connector.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leftSection = find.byKey(const Key('tasks-left-section'));
    final rightSection = find.byKey(const Key('tasks-right-section'));
    final splitter = find.byKey(const Key('tasks-splitter'));
    expect(find.text('Tasks'), findsWidgets);
    expect(tester.getSize(leftSection).width, closeTo(388, 1));
    final rightWidthBeforeDrag = tester.getSize(rightSection).width;

    await tester.drag(splitter, const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(tester.getSize(leftSection).width, greaterThan(388));
    expect(tester.getSize(rightSection).width, lessThan(rightWidthBeforeDrag));
  });
}
