// Smoke test: the app boots to the dashboard without throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coal_mine_inspector/main.dart';

void main() {
  testWidgets('App boots to the Field Inspections dashboard', (tester) async {
    await tester.pumpWidget(const CoalMineInspectorApp());
    await tester.pump();

    expect(find.text('Field Inspections'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
