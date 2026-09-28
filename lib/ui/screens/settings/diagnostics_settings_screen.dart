import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/services/log_service.dart';
import '../../../data/services/performance_recorder.dart';
import '../../../data/services/performance_report_upload.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/artwork_timing.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/settings/clean_settings_typography.dart';
import '../../widgets/settings/preference_tiles.dart';
import '../../../l10n/app_localizations.dart';
import '../../util/error_message.dart';
import 'settings_app_bar.dart';

class DiagnosticsSettingsScreen extends StatefulWidget {
  const DiagnosticsSettingsScreen({super.key});

  @override
  State<DiagnosticsSettingsScreen> createState() =>
      _DiagnosticsSettingsScreenState();
}

class _DiagnosticsSettingsScreenState extends State<DiagnosticsSettingsScreen> {
  LogService get _log => GetIt.instance<LogService>();

  bool _uploading = false;
  String? _performanceUploadProgress;
  final _performance = PerformanceRecorder.instance;
  LogCategory? _filter;

  Future<void> _sendPerformance() async {
    setState(() => _uploading = true);
    try {
      final report = await _performance.report();
      if (report == null) return;
      final documents = await compute(performanceReportDocuments, report);
      String? name;
      for (var i = 0; i < documents.length; i++) {
        if (mounted) setState(() => _performanceUploadProgress = 'Sending part ${i + 1} of ${documents.length}');
        name = await _log.uploadToServer(document: documents[i]);
      }
      if (mounted)
        _showSnack(
          'Performance report sent to server (${documents.length} file${documents.length == 1 ? "" : "s"})${name == null ? "" : ": $name"}',
        );
    } catch (e) {
      if (mounted)
        _showSnack(
          'Could not send report: ${describeError(e, AppLocalizations.of(context))}. The recording is still saved.',
        );
    } finally {
      if (mounted) setState(() { _uploading = false; _performanceUploadProgress = null; });
    }
  }

  Future<void> _copyPerformanceSummary() async {
    final report = await _performance.report();
    if (report == null) return;
    // Android clipboard transactions are bounded; the full journal goes to the server.
    await Clipboard.setData(
      ClipboardData(text: report.split('EVENTS JSONL').first),
    );
    if (mounted) _showSnack('Performance summary copied');
  }

  Future<void> _sendReport() async {
    setState(() => _uploading = true);
    ArtworkTimings.prepareReport();
    try {
      final fileName = await _log.uploadToServer();
      if (!mounted) return;
      _showSnack(
        fileName == null
            ? 'Report sent to server'
            : 'Report sent to server: $fileName',
      );
    } catch (e) {
      if (!mounted) return;
      final detail = describeError(e, AppLocalizations.of(context));
      _showSnack('Could not send report: $detail');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _copyAll() async {
    ArtworkTimings.prepareReport();
    await Clipboard.setData(ClipboardData(text: _log.exportText()));
    _showSnack('Logs copied to clipboard');
  }

  Future<void> _copyEntry(LogEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.format()));
    _showSnack('Entry copied to clipboard');
  }

  void _clearLogs() {
    _log.clear();
    _showSnack('Logs cleared');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _supportsUpload => _log.canUploadToServer;

  Future<void> _pickFilter() async {
    final selected = await showFocusRestoringModalBottomSheet<_FilterChoice>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<LogCategory?>(
          groupValue: _filter,
          onChanged: (value) => Navigator.pop(ctx, _FilterChoice(value)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<LogCategory?>(
                title: const Text('All categories'),
                value: null,
              ),
              for (final category in LogCategory.values)
                RadioListTile<LogCategory?>(
                  title: Text(_categoryLabel(category)),
                  value: category,
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _filter = selected.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RequestInitialFocus(
      child: withCleanSettingsTypography(
        context,
        Scaffold(
          appBar: buildSettingsAppBar(
            context,
            const Text('Diagnostics & Logging'),
          ),
          body: AnimatedBuilder(
            animation: Listenable.merge([_log, _performance]),
            builder: (context, _) => _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final enabled = _log.isEnabled;
    final count = _log.entryCount;
    final hasEntries = count > 0;

    final entries = _log.entries
        .where((e) => _filter == null || e.category == _filter)
        .toList()
        .reversed
        .toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Section(title: 'Performance recording'),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Text(
                  '${_performance.status}\n'
                  'Captures action timings, requests, UI frames, playback and Android resources. '
                  'No media names or credentials. Stops after 30 minutes; keeps three local recordings. '
                  'Nothing is uploaded until you send it.',
                ),
              ),
              _ActionTile(
                icon: _performance.recording
                    ? Icons.stop_circle_outlined
                    : Icons.fiber_manual_record,
                title: _performance.recording
                    ? 'Stop recording (${_performance.elapsedSeconds}s)'
                    : 'Start performance recording',
                subtitle: 'Use Moonfin normally, then return here to send the report.',
                enabled: !_performance.busy && !_uploading,
                onTap: () async {
                  if (_performance.recording) {
                    await _performance.stop();
                  } else {
                    await _performance.start();
                  }
                },
              ),
              _ActionTile(
                icon: Icons.flag_outlined,
                title: 'Mark a slow moment',
                subtitle:
                    '${_performance.markerCount} moments marked in this recording.',
                enabled: _performance.recording,
                onTap: _performance.marker,
              ),
              SwitchListTile(
                title: const Text('Show recording controls'),
                subtitle: const Text(
                  'Small CPU/memory display and a marker button. Hide for timing comparisons.',
                ),
                value: _performance.showOverlay,
                onChanged: _performance.overlay,
              ),
              _ActionTile(
                icon: Icons.cloud_upload_outlined,
                title: 'Send performance report to server',
                subtitle: _performanceUploadProgress ?? 'Sends the full text report to your media server. Large recordings use numbered files.',
                enabled:
                    _performance.hasReport &&
                    _supportsUpload &&
                    !_uploading &&
                    !_performance.busy,
                onTap: _sendPerformance,
              ),
              _ActionTile(
                icon: Icons.copy,
                title: 'Copy performance summary',
                subtitle: 'Stops recording and copies the summary. The server report also includes the full event journal.',
                enabled:
                    _performance.hasReport && !_uploading && !_performance.busy,
                onTap: _copyPerformanceSummary,
              ),
              const _Section(title: 'Logging'),
              SwitchPreferenceTile(
                preference: UserPreferences.diagnosticLoggingEnabled,
                title: 'Enable diagnostic logging',
                subtitle:
                    'Capture media, Seerr login, network and other '
                    'diagnostics so they can be sent to the server as a report.',
                icon: Icons.bug_report,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.crashReportsEnabled,
                title: 'Send crash reports to server',
                subtitle:
                    'Save a report when the app crashes and send it to your '
                    'own server the next time it connects. Nothing is sent '
                    'anywhere else.',
                icon: Icons.report_outlined,
              ),
              _Section(
                title: enabled
                    ? 'Reports ($count entries captured)'
                    : 'Reports',
              ),
              _ActionTile(
                icon: Icons.cloud_upload,
                title: 'Send report to server',
                subtitle: _sendSubtitle(enabled),
                enabled:
                    enabled && hasEntries && _supportsUpload && !_uploading,
                trailing: _uploading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _sendReport,
              ),
              _ActionTile(
                icon: Icons.copy_all,
                title: 'Copy all logs',
                subtitle: 'Copy the full report to the clipboard.',
                enabled: hasEntries,
                onTap: _copyAll,
              ),
              _ActionTile(
                icon: Icons.delete_outline,
                title: 'Clear captured logs',
                subtitle: 'Discard everything in the current buffer.',
                enabled: hasEntries,
                destructive: true,
                onTap: _clearLogs,
              ),
              _Section(
                title: _filter == null
                    ? 'Recent logs'
                    : 'Recent logs (${entries.length} of $count)',
              ),
              _ActionTile(
                icon: Icons.filter_list,
                title: 'Filter',
                subtitle: _filter == null
                    ? 'All categories'
                    : _categoryLabel(_filter!),
                enabled: enabled || hasEntries,
                trailing: const Icon(Icons.expand_more, size: 20),
                onTap: _pickFilter,
              ),
            ],
          ),
        ),
        if (entries.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyState(context, enabled))
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _LogTile(
                entry: entries[index],
                onTap: () => _copyEntry(entries[index]),
              ),
              childCount: entries.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  String _sendSubtitle(bool enabled) {
    if (!enabled) return 'Enable diagnostic logging first.';
    if (!_supportsUpload) return _log.uploadUnavailableReason;
    if (_log.entryCount == 0) return 'No entries captured yet.';
    return 'Upload the captured logs to the active server.';
  }

  Widget _buildEmptyState(BuildContext context, bool enabled) {
    final total = _log.entryCount;
    final filtered = _filter != null && total > 0;

    final IconData icon;
    final String message;
    if (filtered) {
      icon = Icons.filter_list_off;
      message =
          'No ${_categoryLabel(_filter!)} entries. $total captured in other '
          'categories. Tap Filter to change.';
    } else if (enabled) {
      icon = Icons.hourglass_empty;
      message = 'No log entries yet. Reproduce the issue, then send a report.';
    } else {
      icon = Icons.toggle_off_outlined;
      message =
          'Logging is off. Turn it on, reproduce the issue, then send '
          'a report to the server.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          Icon(
            icon,
            size: 40,
            color: AppColorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  static String _categoryLabel(LogCategory category) => switch (category) {
    LogCategory.general => 'General',
    LogCategory.media => 'Media',
    LogCategory.seerr => 'Seerr login',
    LogCategory.network => 'Network',
    LogCategory.auth => 'Authentication',
    LogCategory.playback => 'Playback',
    LogCategory.sync => 'Sync',
    LogCategory.artwork => 'Artwork',
  };
}

class _FilterChoice {
  const _FilterChoice(this.value);
  final LogCategory? value;
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColorScheme.accent,
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.enabled = true,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool enabled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final accent = destructive
        ? AppColorScheme.statusRequested
        : AppColorScheme.accent;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (!event.logicalKey.isSelectKey) return KeyEventResult.ignored;
        if (event is KeyDownEvent && enabled) onTap();
        return KeyEventResult.handled;
      },
      child: TvFocusHighlight(
        builder: (context, focused) {
          final foreground = !enabled
              ? AppColorScheme.onSurface.withValues(alpha: 0.38)
              : focused
              ? AppColors.black.withValues(alpha: 0.87)
              : (destructive ? accent : AppColorScheme.onSurface);
          final iconColor = !enabled
              ? AppColorScheme.onSurface.withValues(alpha: 0.38)
              : focused
              ? AppColors.black.withValues(alpha: 0.7)
              : accent;

          return ListTile(
            enabled: enabled,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            leading: Icon(icon, color: iconColor),
            title: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: foreground.withValues(alpha: 0.7),
              ),
            ),
            trailing: trailing,
            onTap: enabled ? onTap : null,
          );
        },
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry, required this.onTap});

  final LogEntry entry;
  final VoidCallback onTap;

  Color _levelColor() => switch (entry.level) {
    LogLevel.error => AppColorScheme.statusRequested,
    LogLevel.warning => AppColorScheme.statusPending,
    LogLevel.info => AppColorScheme.statusAvailable,
    LogLevel.debug => AppColorScheme.onSurface.withValues(alpha: 0.6),
  };

  @override
  Widget build(BuildContext context) {
    final time = entry.time;
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    final levelColor = _levelColor();

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (!event.logicalKey.isSelectKey) return KeyEventResult.ignored;
        if (event is KeyDownEvent) onTap();
        return KeyEventResult.handled;
      },
      child: TvFocusHighlight(
        builder: (context, focused) {
          final textColor = focused
              ? AppColors.black.withValues(alpha: 0.87)
              : AppColorScheme.onSurface;
          return ListTile(
            dense: true,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            onTap: onTap,
            leading: Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: levelColor,
                borderRadius: AppRadius.circular(2),
              ),
            ),
            title: Text(
              '$hh:$mm:$ss  ${entry.level.label}  ${entry.category.label}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: focused
                    ? AppColors.black.withValues(alpha: 0.7)
                    : levelColor,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: textColor,
                  ),
                ),
                if (entry.error != null)
                  Text(
                    entry.error!,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: focused
                          ? AppColors.black.withValues(alpha: 0.7)
                          : AppColorScheme.statusRequested,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
