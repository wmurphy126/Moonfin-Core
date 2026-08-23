import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/detail/item_detail_screen.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _trackTitle = 'A Matter of Trust - The Bridge to Russia';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    PlatformDetection.setTvMode(false);
    PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic);
  });

  tearDown(() async {
    PlatformDetection.setTvMode(false);
    PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic);
    await GetIt.instance.reset();
  });

  Future<void> pumpTrack(
    WidgetTester tester,
    double width, {
    InterfaceLayout layout = InterfaceLayout.automatic,
  }) async {
    PlatformDetection.setInterfaceLayout(layout);
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const track = AggregatedItem(
      id: 'track-1',
      serverId: 'server-1',
      rawData: {
        'Type': 'Audio',
        'Name': _trackTitle,
        'Artists': ['Billy Joel'],
        'ProductionYear': 2003,
        'RunTimeTicks': 2900000000,
        'IndexNumber': 1,
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: TrackTile(
            track: track,
            index: 1,
            currentIndex: 0,
            totalCount: 1,
            reorderable: false,
            reorderIndex: 0,
            onTap: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('compact audio row moves runtime below the title', (
    tester,
  ) async {
    await pumpTrack(tester, 390);

    expect(find.text('Billy Joel • 4:50'), findsOneWidget);
    expect(find.text('2003  •  4:50'), findsNothing);
    expect(
      tester.getSize(find.text(_trackTitle)).width,
      greaterThan(220),
      reason: 'the title should receive the width freed by trailing metadata',
    );
  });

  testWidgets('wide audio row keeps year and runtime trailing', (tester) async {
    await pumpTrack(tester, 800, layout: InterfaceLayout.desktop);

    expect(find.text('Billy Joel'), findsOneWidget);
    expect(find.text('2003  •  4:50'), findsOneWidget);
    expect(find.text('Billy Joel • 4:50'), findsNothing);
  });
}
