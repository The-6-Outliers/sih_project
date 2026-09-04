// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'core/database/database_helper.dart';
import 'core/services/sync_service.dart';
import 'firebase_options.dart';
import 'screens/dashboard_screen.dart';

/// Override at build time: `--dart-define=API_BASE_URL=https://...`
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://api.coalgov.example',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (kIsWeb) {
    runApp(const CoalMineInspectorApp());
    return;
  }

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
      home: const InspectorAuthGate(),
    );
  }
}

class InspectorAuthGate extends StatelessWidget {
  const InspectorAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return user == null
            ? const InspectorLoginScreen()
            : DashboardScreen(inspectorId: user.uid);
      },
    );
  }
}

class InspectorLoginScreen extends StatefulWidget {
  const InspectorLoginScreen({super.key});

  @override
  State<InspectorLoginScreen> createState() => _InspectorLoginScreenState();
}

class _InspectorLoginScreenState extends State<InspectorLoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'invalid-credential'
          ? 'Email or password is incorrect.'
          : e.message ?? 'Could not sign in.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inspector access')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shield_outlined, size: 64),
                const SizedBox(height: 12),
                const Text('Sign in to report field observations', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Work email')),
                const SizedBox(height: 12),
                TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(onPressed: _busy ? null : _signIn, icon: const Icon(Icons.login), label: Text(_busy ? 'Signing in...' : 'Sign in')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
