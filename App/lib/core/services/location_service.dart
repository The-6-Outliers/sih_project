// lib/core/services/location_service.dart
import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Typed failure modes for [LocationService].
enum LocationErrorType {
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  mockDetected,
  timeout,
  unknown,
}

class LocationException implements Exception {
  final LocationErrorType type;
  final String message;

  const LocationException(this.type, this.message);

  @override
  String toString() => 'LocationException(${type.name}): $message';
}

/// Immutable snapshot of a single GNSS fix, carrying the mock/spoof verdict.
class LocationFix {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double altitude;
  final double heading;
  final double speed;

  /// `true` when Android reported the fix as produced by a mock provider.
  final bool isMocked;

  final DateTime timestamp;

  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.heading,
    required this.speed,
    required this.isMocked,
    required this.timestamp,
  });

  factory LocationFix.fromPosition(Position position) {
    return LocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      altitude: position.altitude,
      heading: position.heading,
      speed: position.speed,
      isMocked: position.isMocked,
      timestamp: position.timestamp.toUtc(),
    );
  }

  Map<String, Object?> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'altitude': altitude,
        'heading': heading,
        'speed': speed,
        'is_mocked': isMocked,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  @override
  String toString() =>
      'LocationFix($latitude, $longitude +/-${accuracy}m, mocked: $isMocked)';
}

/// Thin, testable wrapper over `geolocator` that:
///  * verifies the location service is on,
///  * checks / requests runtime permission,
///  * fetches a one-shot fix using [LocationSettings],
///  * surfaces mock-location detection via [Position.isMocked].
class LocationService {
  const LocationService();

  /// Whether the device's location service (GPS/network) is enabled.
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  /// Ensures the app holds at least "while in use" permission.
  ///
  /// Throws [LocationException] for [LocationErrorType.permissionDenied] or
  /// [LocationErrorType.permissionDeniedForever] when it cannot be obtained.
  Future<LocationPermission> ensurePermission() async {
    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    switch (permission) {
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        throw const LocationException(
          LocationErrorType.permissionDenied,
          'Location permission was denied.',
        );
      case LocationPermission.deniedForever:
        throw const LocationException(
          LocationErrorType.permissionDeniedForever,
          'Location permission is permanently denied. Enable it from system settings.',
        );
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        return permission;
    }
  }

  /// One-shot high-accuracy fix.
  ///
  /// * [timeout] is enforced through `LocationSettings.timeLimit`.
  /// * When [rejectMocked] is `true` and the OS flags the fix as mocked, throws
  ///   [LocationException] with [LocationErrorType.mockDetected].
  Future<LocationFix> getCurrentFix({
    LocationAccuracy accuracy = LocationAccuracy.best,
    int distanceFilter = 0,
    Duration timeout = const Duration(seconds: 20),
    bool rejectMocked = false,
  }) async {
    if (!await isServiceEnabled()) {
      throw const LocationException(
        LocationErrorType.serviceDisabled,
        'Location services are disabled on this device.',
      );
    }

    await ensurePermission();

    final settings = LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      timeLimit: timeout,
    );

    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(locationSettings: settings);
    } on TimeoutException {
      throw const LocationException(
        LocationErrorType.timeout,
        'Timed out while acquiring a location fix.',
      );
    } on LocationServiceDisabledException {
      throw const LocationException(
        LocationErrorType.serviceDisabled,
        'Location services were turned off during the request.',
      );
    } on PermissionDeniedException {
      throw const LocationException(
        LocationErrorType.permissionDenied,
        'Location permission was revoked during the request.',
      );
    } catch (e) {
      throw LocationException(
        LocationErrorType.unknown,
        'Failed to acquire location: $e',
      );
    }

    final fix = LocationFix.fromPosition(position);

    if (rejectMocked && fix.isMocked) {
      throw const LocationException(
        LocationErrorType.mockDetected,
        'A mock (spoofed) location was detected. The fix was rejected.',
      );
    }

    return fix;
  }

  /// Best-effort last known fix (no I/O wait). Returns `null` if unavailable.
  Future<LocationFix?> getLastKnownFix() async {
    try {
      final position = await Geolocator.getLastKnownPosition();
      return position == null ? null : LocationFix.fromPosition(position);
    } catch (_) {
      return null;
    }
  }

  /// Continuous stream of fixes for live map tracking during an inspection walk.
  Stream<LocationFix> watchPosition({
    LocationAccuracy accuracy = LocationAccuracy.high,
    int distanceFilter = 5,
    Duration? timeLimit,
  }) {
    final settings = LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      timeLimit: timeLimit,
    );
    return Geolocator.getPositionStream(locationSettings: settings)
        .map(LocationFix.fromPosition);
  }

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  double distanceBetweenMeters(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) =>
      Geolocator.distanceBetween(startLat, startLng, endLat, endLng);
}
