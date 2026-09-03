// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';

import 'core/database/database_helper.dart';
import 'core/services/sync_service.dart';
import 'screens/dashboard_screen.dart';

/// Override at build time: `--dart-define=API_BASE_URL=https://...`
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://api.coalgov.example',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Warm up SQLite: opens the connection, runs onConfigure (FK pragma),
  //    onCreate / onUpgrade, so the first screen never waits on schema work.
  final db = DatabaseHelper.instance;
  await db.database;

  // 2. Initialise the sync engine singleton and begin listening to
  //    connectivity. start() also re-queues rows left in `processing` by a
  //    previous hard kill.
  final sync = SyncService.ensureInitialised(
    config: const SyncConfig(baseUrl: kApiBaseUrl),
    database: db,
    tokenProvider: _readAuthToken,
  );
  try {
    await sync.start();
  } catch (e, st) {
    debugPrint('SyncService.start failed (continuing offline): $e\n$st');
  }

  runApp(const CoalMineInspectorApp());
}

/// Wire to secure storage / auth store. `null` == unauthenticated dev build.
FutureOr<String?> _readAuthToken() => null;

class CoalMineInspectorApp extends StatelessWidget {
  const CoalMineInspectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1B5E20),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1B5E20),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Coal Mine Inspector',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        appBarTheme: AppBarTheme(
          backgroundColor: lightScheme.primary,
          foregroundColor: lightScheme.onPrimary,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        cardTheme: const CardThemeData(
          elevation: 1,
          clipBehavior: Clip.antiAlias,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        appBarTheme: AppBarTheme(
          backgroundColor: darkScheme.surface,
          foregroundColor: darkScheme.onSurface,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
