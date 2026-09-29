import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

/// One active journal and two previous recordings, all in app-private storage.
class PerformanceStore {
  PerformanceStore({String? directory}) : _directory = directory;
  String? _directory;
  Future<String> _dir() async => _directory ??=
      '${(await getApplicationSupportDirectory()).path}/performance-recordings';

  Future<bool> exists() async =>
      File('${await _dir()}/current.summary').exists();

  Future<void> start() async {
    final path = await _dir();
    await Isolate.run(() async {
      await Directory(path).create(recursive: true);
      for (final suffix in ['events', 'summary']) {
        final oldest = File('$path/previous2.$suffix');
        if (await oldest.exists()) await oldest.delete();
        final previous = File('$path/previous1.$suffix');
        if (await previous.exists()) await previous.rename(oldest.path);
        final current = File('$path/current.$suffix');
        if (await current.exists()) await current.rename(previous.path);
      }
    });
  }

  Future<bool> append(List<String> lines, String summary) async {
    final path = await _dir();
    return Isolate.run(() async {
      await Directory(path).create(recursive: true);
      final journal = File('$path/current.events');
      final size = await journal.exists() ? await journal.length() : 0;
      final batch = '${lines.join('\n')}\n';
      final fits = size + batch.length <= 12 * 1024 * 1024;
      if (fits)
        await journal.writeAsString(batch, mode: FileMode.append, flush: true);
      final temp = File('$path/current.summary.tmp');
      await temp.writeAsString(summary, flush: true);
      final target = File('$path/current.summary');
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      return fits;
    });
  }

  Future<String?> read() async {
    final path = await _dir();
    return Isolate.run(() async {
      final summary = File('$path/current.summary');
      final journal = File('$path/current.events');
      if (!await summary.exists()) return null;
      return '${await summary.readAsString()}\nEVENTS JSONL (microseconds from recording start)\n'
          '${await journal.exists() ? await journal.readAsString() : "Journal unavailable"}';
    });
  }
}
