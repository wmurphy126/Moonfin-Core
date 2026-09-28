class PerformanceStore {
  PerformanceStore({String? directory});
  String _events = '', _summary = '';
  Future<bool> exists() async => _summary.isNotEmpty;
  Future<void> start() async {
    _events = '';
    _summary = '';
  }

  Future<bool> append(List<String> lines, String summary) async {
    _summary = summary;
    final batch = '${lines.join('\n')}\n';
    final fits = _events.length + batch.length <= 12 * 1024 * 1024;
    if (fits) _events += batch;
    return fits;
  }

  Future<String?> read() async =>
      _summary.isEmpty ? null : '$_summary\nEVENTS JSONL\n$_events';
}
