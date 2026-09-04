// lib/screens/dashboard_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../core/database/database_helper.dart';
import '../core/services/sync_service.dart';
import '../models/inspection.dart';
import 'create_inspection_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.inspectorId});

  final String inspectorId;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final DateFormat _fmt = DateFormat('dd MMM - HH:mm');

  List<Inspection> _inspections = const [];
  int _pendingCount = 0;
  bool _loading = true;
  bool _online = SyncService.isInitialised && SyncService.instance.isOnline;
  bool _syncing = false;

  StreamSubscription<bool>? _onlineSub;
  StreamSubscription<SyncResult>? _syncSub;

  @override
  void initState() {
    super.initState();

    if (SyncService.isInitialised) {
      final sync = SyncService.instance;
      _online = sync.isOnline;
      _syncing = sync.isSyncing;

      _onlineSub = sync.onOnlineStatusChanged.listen((online) {
        if (mounted) setState(() => _online = online);
      });

      _syncSub = sync.onSyncComplete.listen((result) {
        if (!mounted) return;
        setState(() => _syncing = false);
        _reload();
        if (result.hadWork && !result.skipped) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Sync complete - ${result.succeeded} sent'
                '${result.failed > 0 ? ', ${result.failed} failed' : ''}.',
              ),
            ),
          );
        }
      });
    }

    _reload();
  }

  @override
  void dispose() {
    _onlineSub?.cancel();
    _syncSub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    if (kIsWeb) {
      if (!mounted) return;
      setState(() {
        _inspections = const [];
        _pendingCount = 0;
        _loading = false;
      });
      return;
    }
    final items = await _db.getInspections(limit: 200);
    final pending = await _db.countPendingSync();
    if (!mounted) return;
    setState(() {
      _inspections = items;
      _pendingCount = pending;
      _loading = false;
    });
  }

  Future<void> _onRefresh() async {
    if (kIsWeb) {
      await _reload();
      return;
    }
    if (!SyncService.isInitialised) {
      await _reload();
      return;
    }
    setState(() => _syncing = true);
    await SyncService.instance.syncPendingItems();
    await _reload();
    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CreateInspectionScreen(inspectorId: widget.inspectorId),
      ),
    );
    if (created == true) {
      await _reload();
    }
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Field Inspections'),
        actions: [
          _OnlineStatusChip(online: _online),
          const SizedBox(width: 8),
          _OutboxBadge(
            count: _pendingCount,
            busy: _syncing,
            onTap: _syncing ? null : _onRefresh,
          ),
          const SizedBox(width: 12),
        ],
        bottom: _syncing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        icon: const Icon(Icons.add_a_photo),
        label: const Text('Log observation'),
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _inspections.isEmpty
                ? _EmptyState(online: _online)
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    itemCount: _inspections.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _InspectionTile(inspection: _inspections[i], fmt: _fmt),
                  ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AppBar widgets
// ---------------------------------------------------------------------------

class _OnlineStatusChip extends StatelessWidget {
  const _OnlineStatusChip({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color fg = online ? Colors.green.shade100 : scheme.onError;
    final Color bg = online ? Colors.green.shade700 : scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(online ? Icons.cloud_done : Icons.cloud_off, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            online ? 'Online' : 'Offline',
            style: TextStyle(
                color: fg, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _OutboxBadge extends StatelessWidget {
  const _OutboxBadge({required this.count, this.busy = false, this.onTap});
  final int count;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    return Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      offset: const Offset(-2, 2),
      child: IconButton(
        tooltip: busy
            ? 'Syncing...'
            : count > 0
                ? 'Sync now - $count item(s) waiting'
                : 'Sync now - outbox empty',
        onPressed: onTap,
        icon: busy
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: onPrimary),
              )
            : Icon(count > 0 ? Icons.sync_problem : Icons.sync, color: onPrimary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// List item
// ---------------------------------------------------------------------------

class _InspectionTile extends StatelessWidget {
  const _InspectionTile({required this.inspection, required this.fmt});

  final Inspection inspection;
  final DateFormat fmt;

  @override
  Widget build(BuildContext context) {
    final (IconData syncIcon, Color syncColor) =
        _syncBadge(inspection.syncStatus);

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Container(
          width: 12,
          height: 44,
          decoration: BoxDecoration(
            color: _severityColor(inspection.severity),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        title: Text(
          inspection.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${inspection.mineCode} - ${_prettyType(inspection.inspectionType)}\n'
            '${fmt.format(inspection.createdAt.toLocal())}'
            '${inspection.isMocked ? '  -  ! mock GPS' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(syncIcon, color: syncColor, size: 22),
            const SizedBox(height: 2),
            Text(
              inspection.syncStatus.name,
              style: TextStyle(fontSize: 10, color: syncColor),
            ),
          ],
        ),
      ),
    );
  }

  static String _prettyType(String slug) =>
      slug.replaceAll('_', ' ').replaceAll('-', ' ').trim();

  static Color _severityColor(InspectionSeverity s) {
    switch (s) {
      case InspectionSeverity.low:
        return Colors.green;
      case InspectionSeverity.medium:
        return Colors.amber.shade700;
      case InspectionSeverity.high:
        return Colors.deepOrange;
      case InspectionSeverity.critical:
        return Colors.red.shade700;
    }
  }

  static (IconData, Color) _syncBadge(InspectionSyncStatus s) {
    switch (s) {
      case InspectionSyncStatus.pending:
        return (Icons.cloud_upload_outlined, Colors.blueGrey);
      case InspectionSyncStatus.processing:
        return (Icons.sync, Colors.blue);
      case InspectionSyncStatus.synced:
        return (Icons.cloud_done_outlined, Colors.green);
      case InspectionSyncStatus.failed:
        return (Icons.error_outline, Colors.red);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.25),
        Icon(Icons.assignment_outlined,
            size: 64, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        const Center(child: Text('No inspections logged yet.')),
        const SizedBox(height: 4),
        Center(
          child: Text(
            online
                ? 'Tap "Log observation" to record your first one.'
                : 'You are offline - records will sync automatically once connected.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
