import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/services/performance_report_upload.dart';

void main() {
  test('small reports stay unchanged', () {
    expect(performanceReportDocuments('small report'), ['small report']);
  });

  test(
    'numbered UTF-8 documents fit the server cap and reconstruct exactly',
    () {
      final report =
          'Started UTC: 2026-09-28T05:00:00.000Z\n'
          '${'{"event":"test","value":"é😀"}\n' * 90000}';
      final documents = performanceReportDocuments(report);
      expect(documents.length, greaterThan(1));
      final reassembled = StringBuffer();
      for (var i = 0; i < documents.length; i++) {
        final document = documents[i];
        expect(utf8.encode(document).length, lessThanOrEqualTo(900000));
        expect(document, contains('part ${i + 1} of ${documents.length}'));
        expect(document, contains('2026-09-28T05:00:00.000Z'));
        reassembled.write(document.substring(document.indexOf('\n\n') + 2));
      }
      expect(reassembled.toString(), report);
    },
  );

  test('oversized individual lines split only between UTF-8 characters', () {
    final report = '😀é' * 400000;
    final documents = performanceReportDocuments(report);
    expect(documents.every((doc) => utf8.encode(doc).length <= 900000), isTrue);
    expect(
      documents.map((doc) => doc.substring(doc.indexOf('\n\n') + 2)).join(),
      report,
    );
  });
}
