import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/ui/screens/playback/appletv_player_host_screen.dart';
import 'package:moonfin/ui/widgets/playback/player_loading_overlay.dart';
import 'package:playback_core/playback_core.dart';

class _MockPlaybackManager extends Mock implements PlaybackManager {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockPlaybackManager manager;
  late QueueService queue;
  late PlayerState playerState;
  late StreamController<PlaybackBringupState> bringupController;

  setUp(() {
    manager = _MockPlaybackManager();
    queue = QueueService();
    playerState = PlayerState();
    bringupController = StreamController<PlaybackBringupState>.broadcast();

    when(() => manager.bringupState).thenReturn(
      const PlaybackBringupState.idle(),
    );
    when(() => manager.bringupStateStream).thenAnswer(
      (_) => bringupController.stream,
    );
    when(() => manager.queueService).thenReturn(queue);
    when(() => manager.sessionEndedStream).thenAnswer(
      (_) => const Stream<void>.empty(),
    );
    when(() => manager.state).thenReturn(playerState);
    when(
      () => manager.stop(userInitiated: any(named: 'userInitiated')),
    ).thenAnswer((_) async {});

    GetIt.instance.registerSingleton<PlaybackManager>(manager);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await bringupController.close();
    queue.dispose();
    playerState.dispose();
  });

  testWidgets('shows launch feedback until playback is ready', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AppleTvPlayerHostScreen()),
    );

    expect(find.byType(PlayerLoadingOverlay), findsOneWidget);

    bringupController.add(
      const PlaybackBringupState(phase: PlaybackBringupPhase.resolving),
    );
    await tester.pump();
    expect(find.byType(PlayerLoadingOverlay), findsOneWidget);

    bringupController.add(
      const PlaybackBringupState(phase: PlaybackBringupPhase.ready),
    );
    await tester.pump();
    expect(find.byType(PlayerLoadingOverlay), findsNothing);
  });

  testWidgets('removes launch feedback when playback fails', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AppleTvPlayerHostScreen()),
    );

    bringupController.add(
      const PlaybackBringupState(phase: PlaybackBringupPhase.failed),
    );
    await tester.pump();

    expect(find.byType(PlayerLoadingOverlay), findsNothing);
  });
}
