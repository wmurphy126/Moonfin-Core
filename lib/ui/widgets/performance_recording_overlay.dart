import 'package:flutter/material.dart';

import '../../data/services/performance_recorder.dart';

/// A small in-app marker, without Android overlay permissions or frame polling.
class PerformanceRecordingOverlay extends StatelessWidget {
  const PerformanceRecordingOverlay({super.key});
  @override
  Widget build(BuildContext context) {
    final recorder = PerformanceRecorder.instance;
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        if (!recorder.recording || !recorder.showOverlay)
          return const SizedBox.shrink();
        return Positioned(
          right: 12,
          top: MediaQuery.paddingOf(context).top + 8,
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'REC ${recorder.elapsedSeconds}s\n'
                    'CPU ${recorder.cpuPercent?.toStringAsFixed(0) ?? "—"}%  '
                    'PSS ${recorder.memoryMiB?.toStringAsFixed(0) ?? "—"} MiB',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  IconButton(
                    tooltip: 'Mark this slow moment',
                    onPressed: recorder.marker,
                    icon: const Icon(Icons.flag_outlined, color: Colors.orange),
                  ),
                  IconButton(
                    tooltip: 'Hide recording overlay',
                    onPressed: () => recorder.overlay(false),
                    icon: const Icon(
                      Icons.visibility_off_outlined,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
