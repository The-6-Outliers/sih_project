import 'package:firebase_core/firebase_core.dart';

/// Shared Firebase project configuration for the Flutter inspector app.
/// Keep this file limited to public client configuration; never add service keys.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return const FirebaseOptions(
      apiKey: 'AIzaSyDl5ZcplR1Q1QQWrx3F-T6IyyzwH5vKzIs',
      appId: '1:87907194843:web:1f6c9803c026b8c16f79fe',
      messagingSenderId: '87907194843',
      projectId: 'sih-2026-b6739',
      authDomain: 'sih-2026-b6739.firebaseapp.com',
      storageBucket: 'sih-2026-b6739.firebasestorage.app',
      measurementId: 'G-X4CKXYQ3EG',
    );
  }
}
