import 'dart:convert';

/// Jellyfin's ClientLog/Document limit is 1,000,000 bytes, including headers
/// written into the document. Keep a margin for proxies and preserve all data.
List<String> performanceReportDocuments(String report) {
  const maxBytes = 900000;
  const payloadBytes = maxBytes - 512;
  final bytes = utf8.encode(report);
  if (bytes.length <= maxBytes) return [report];
  final chunks = <String>[];
  var start = 0;
  while (start < bytes.length) {
    var end = (start + payloadBytes).clamp(0, bytes.length);
    if (end < bytes.length) {
      // Prefer whole JSONL records. Fall back to a UTF-8 boundary for a long line.
      final floor = end - 8192;
      var newline = end - 1;
      while (newline > floor && bytes[newline] != 10) {
        newline--;
      }
      if (bytes[newline] == 10) {
        end = newline + 1;
      } else {
        while ((bytes[end] & 0xc0) == 0x80) {
          end--;
        }
      }
    }
    chunks.add(utf8.decode(bytes.sublist(start, end)));
    start = end;
  }
  final started =
      RegExp(
        r'^Started UTC: ([0-9T:.Z+-]+)$',
        multiLine: true,
      ).firstMatch(report)?.group(1) ??
      'unknown';
  return [
    for (var i = 0; i < chunks.length; i++)
      'Moonfin performance report — recording $started — part ${i + 1} of ${chunks.length}\n'
          'Join the payloads after this blank line in part order for the full report.\n\n'
          '${chunks[i]}',
  ];
}
