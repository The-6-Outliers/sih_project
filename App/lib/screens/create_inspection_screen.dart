// lib/screens/create_inspection_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/database/database_helper.dart';
import '../core/services/camera_service.dart';
import '../core/services/location_service.dart';
import '../core/services/sync_service.dart';
import '../models/inspection.dart';
import '../models/inspection_media.dart';
import '../models/sync_queue_item.dart';

const int _kMaxPhotos = 3;

const List<String> _kMineSeams = <String>[
  'Seam I',
  'Seam III-A',
  'Seam V',
  'Seam VII Top',
  'Seam IX Bottom',
  'Seam XI',
  'Seam XIV',
];

enum _Shift {
  morning('Morning'),
  afternoon('Afternoon'),
  night('Night');

  const _Shift(this.label);
  final String label;
}

enum _Hazard {
  strataControl('Strata Control', 'strata_control'),
  gasVentilation('Gas / Ventilation', 'gas_ventilation'),
  haulage('Haulage', 'haulage'),
  dustEnvironment('Dust / Environment', 'dust_environment');

  const _Hazard(this.label, this.slug);
  final String label;
  final String slug;
}

class CreateInspectionScreen extends StatefulWidget {
  const CreateInspectionScreen({
    super.key,
    this.mineCode = 'WCL-UNIT-01',
    this.inspectorId = 'INSP-SELF',
  });

  /// The mine the signed-in inspector is assigned to (from the session in a
  /// real build).
  final String mineCode;
  final String inspectorId;

  @override
  State<CreateInspectionScreen> createState() => _CreateInspectionScreenState();
}

class _CreateInspectionScreenState extends State<CreateInspectionScreen> {
  static const LocationService _locationService = LocationService();
  final CameraService _cameraService = CameraService();
  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Generated once so media files are namespaced under the same id we persist.
  late final String _inspectionId = const Uuid().v4();

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();

  String? _seam;
  _Shift? _shift;
  _Hazard? _hazard;
  InspectionSeverity _severity = InspectionSeverity.low;

  final List<InspectionMedia> _photos = <InspectionMedia>[];

  LocationFix? _fix;
  bool _locating = false;
  String? _locationError;

  /// True when [_fix] came from the OS last-known cache, not a live fix
  /// (e.g. underground / offline with no satellite lock).
  bool _fixIsStale = false;

  bool _capturing = false;
  bool _submitting = false;

  /// Set once the record is handed to the DB so [dispose] does not purge media.
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    _fetchLocation();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    if (!_committed && _photos.isNotEmpty) {
      // Abandoned draft: clean up orphaned image files.
      unawaited(_cameraService.purgeInspectionMedia(_inspectionId));
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // LOCATION
  // ---------------------------------------------------------------------------

  Future<void> _fetchLocation() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final fix = await _locationService.getCurrentFix(
        timeout: const Duration(seconds: 15),
      );
      if (!mounted) return;
      setState(() {
        _fix = fix;
        _fixIsStale = false;
      });
    } on LocationException catch (e) {
      await _fallBackToLastKnown(e.message);
    } catch (e) {
      await _fallBackToLastKnown('Location failed: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// No live fix (underground / offline / indoors): use the last position the
  /// OS cached while the phone still had sky view or a network. The inspection
  /// is still geo-tagged, flagged as an approximate last-known location.
  Future<void> _fallBackToLastKnown(String liveError) async {
    LocationFix? last;
    try {
      last = await _locationService.getLastKnownFix();
    } catch (_) {
      last = null;
    }
    if (!mounted) return;
    setState(() {
      if (last != null) {
        _fix = last;
        _fixIsStale = true;
        _locationError = null;
      } else {
        _locationError = '$liveError No cached location either - '
            'get one fix outdoors first, then return here.';
      }
    });
  }

  String _fixAge(DateTime ts) {
    final d = DateTime.now().toUtc().difference(ts.toUtc());
    if (d.inMinutes < 1) return '${d.inSeconds}s ago';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  // ---------------------------------------------------------------------------
  // PHOTOS
  // ---------------------------------------------------------------------------

  Future<void> _capturePhoto() async {
    if (_photos.length >= _kMaxPhotos || _capturing) return;
    setState(() => _capturing = true);
    try {
      final media = await _cameraService.captureFromCamera(
        inspectionId: _inspectionId,
        latitude: _fix?.latitude,
        longitude: _fix?.longitude,
      );
      if (!mounted) return;
      if (media != null) {
        setState(() => _photos.add(media));
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Camera error: $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _removePhoto(InspectionMedia media) {
    setState(() => _photos.remove(media));
    unawaited(_cameraService.deleteLocalFile(media));
  }

  // ---------------------------------------------------------------------------
  // SUBMIT - local commit only, sync fired asynchronously, screen pops at once
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_fix == null) {
      _snack('Still acquiring a GPS fix - try again in a moment.');
      return;
    }
    if (_submitting) return;

    // Capture messenger/navigator before any await so we never touch a stale
    // BuildContext after popping.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    setState(() => _submitting = true);

    // On web preview, skip database save and show success
    if (kIsWeb) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Web preview: observation recorded')),
      );
      navigator.pop(true);
      return;
    }

    final now = DateTime.now().toUtc();
    final fix = _fix!;

    final inspection = Inspection(
      id: _inspectionId,
      mineCode: widget.mineCode,
      inspectorId: widget.inspectorId,
      inspectionType: _hazard!.slug,
      title: _titleCtrl.text.trim(),
      // Seam + shift are captured structurally in the notes header; the wire
      // payload snapshot in the outbox row carries the full context too.
      notes: 'Seam: ${_seam!} - Shift: ${_shift!.label}'
          '${_notesCtrl.text.trim().isEmpty ? '' : '\n\n${_notesCtrl.text.trim()}'}',
      severity: _severity,
      latitude: fix.latitude,
      longitude: fix.longitude,
      accuracy: fix.accuracy,
      altitude: fix.altitude,
      heading: fix.heading,
      speed: fix.speed,
      isMocked: fix.isMocked,
      locationTimestamp: fix.timestamp,
      syncStatus: InspectionSyncStatus.pending,
      createdAt: now,
      updatedAt: now,
    );

    final syncItem = SyncQueueItem.forInspection(
      inspection,
      media: _photos,
      priority: switch (_severity) {
        InspectionSeverity.critical => 100,
        InspectionSeverity.high => 50,
        InspectionSeverity.medium => 10,
        InspectionSeverity.low => 0,
      },
    );

    try {
      // Single atomic transaction: inspection + media + outbox entry.
      await _db.saveInspectionWithSync(
        inspection: inspection,
        media: _photos,
        syncItem: syncItem,
      );
      _committed = true;
    } catch (e) {
      if (mounted) setState(() => _submitting = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save inspection: $e')),
      );
      return;
    }

    // Fire-and-forget. The UI must never wait on the network here.
    if (SyncService.isInitialised) {
      unawaited(SyncService.instance.syncPendingItems());
    }

    navigator.pop(true);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Inspection saved locally - syncing in the background.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Observation')),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _sectionTitle(context, 'Location'),
            const SizedBox(height: 8),
            _locationCard(context),
            const SizedBox(height: 20),

            _sectionTitle(
                context, 'Evidence photos  (${_photos.length}/$_kMaxPhotos)'),
            const SizedBox(height: 8),
            _photosCard(context),
            const SizedBox(height: 20),

            _sectionTitle(context, 'Details'),
            const SizedBox(height: 8),

            TextFormField(
              controller: _titleCtrl,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title / summary',
                hintText: 'e.g. Loose roof strata near junction B4',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().length < 4)
                  ? 'Enter a short summary (min 4 characters)'
                  : null,
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: _seam,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Mine seam',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s in _kMineSeams)
                  DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: (v) => setState(() => _seam = v),
              validator: (v) => v == null ? 'Select a seam' : null,
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<_Shift>(
              initialValue: _shift,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Shift',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s in _Shift.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (v) => setState(() => _shift = v),
              validator: (v) => v == null ? 'Select a shift' : null,
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<_Hazard>(
              initialValue: _hazard,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Hazard category',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final h in _Hazard.values)
                  DropdownMenuItem(value: h, child: Text(h.label)),
              ],
              onChanged: (v) => setState(() => _hazard = v),
              validator: (v) => v == null ? 'Select a hazard category' : null,
            ),
            const SizedBox(height: 20),

            Text('Severity', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<InspectionSeverity>(
                segments: const [
                  ButtonSegment(
                      value: InspectionSeverity.low, label: Text('Low')),
                  ButtonSegment(
                      value: InspectionSeverity.medium, label: Text('Medium')),
                  ButtonSegment(
                      value: InspectionSeverity.high, label: Text('High')),
                  ButtonSegment(
                      value: InspectionSeverity.critical,
                      label: Text('Critical')),
                ],
                selected: {_severity},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _severity = s.first),
              ),
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _notesCtrl,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: const Icon(Icons.save_alt),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_submitting ? 'Saving...' : 'Save inspection'),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      );

  Widget _locationCard(BuildContext context) {
    final Widget content;
    if (_locating) {
      content = const Row(
        children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Acquiring GPS fix...'),
        ],
      );
    } else if (_fix != null) {
      final f = _fix!;
      content = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            avatar: const Icon(Icons.my_location, size: 18),
            label: Text('Lat ${f.latitude.toStringAsFixed(5)}'),
          ),
          Chip(label: Text('Lng ${f.longitude.toStringAsFixed(5)}')),
          Chip(label: Text('+/- ${f.accuracy.toStringAsFixed(1)} m')),
          if (_fixIsStale)
            Chip(
              avatar: const Icon(Icons.history, size: 18),
              label: Text('Last known - ${_fixAge(f.timestamp)}'),
              backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            ),
          if (f.isMocked)
            Chip(
              avatar: const Icon(Icons.warning_amber, size: 18),
              label: const Text('MOCK LOCATION'),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
            ),
          IconButton(
            tooltip: _fixIsStale ? 'Try for a live fix' : 'Refresh location',
            onPressed: _fetchLocation,
            icon: const Icon(Icons.refresh),
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _locationError ?? 'Location unavailable.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _fetchLocation,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Align(alignment: Alignment.centerLeft, child: content),
      ),
    );
  }

  Widget _photosCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount:
                    _photos.length + (_photos.length < _kMaxPhotos ? 1 : 0),
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  if (index < _photos.length) {
                    return _thumbnail(_photos[index]);
                  }
                  return _addPhotoTile(context);
                },
              ),
            ),
            if (_photos.length >= _kMaxPhotos) ...[
              const SizedBox(height: 8),
              Text(
                'Maximum of $_kMaxPhotos photos reached.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(InspectionMedia media) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(
            File(media.localPath),
            width: 92,
            height: 92,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 92,
              height: 92,
              color: Colors.grey.shade300,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
        Positioned(
          top: -10,
          right: -10,
          child: IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            tooltip: 'Remove photo',
            onPressed: () => _removePhoto(media),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    );
  }

  Widget _addPhotoTile(BuildContext context) {
    return InkWell(
      onTap: _capturing ? null : _capturePhoto,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 92,
        height: 92,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Center(
          child: _capturing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_a_photo_outlined),
        ),
      ),
    );
  }
}
