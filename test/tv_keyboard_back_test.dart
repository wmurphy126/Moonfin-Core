import 'dart:async';

import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The caret blink never stops on its own, so settle with fixed pumps
/// instead of pumpAndSettle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The app's back handling asks the keyboard to claim the press before it
/// pops anything, so these pin the answers it relies on.
void main() {
  const appleTvSystemChannel = MethodChannel('moonfin/appletv_system');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleTvSystemChannel, null);
  });

  testWidgets('closing the top keyboard leaves the page it belongs to up',
      (tester) async {
    final controller = TextEditingController(text: 'dune');
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<CustomTVTextFieldState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Text('search results'),
              CustomTVTextField(
                key: fieldKey,
                controller: controller,
                popParentOnKeyboardClose: false,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      CustomTVTextField.closeTopKeyboard(),
      isFalse,
      reason: 'nothing open, so back belongs to whoever asks next',
    );

    fieldKey.currentState!.openKeyboard();
    await _settle(tester);
    expect(find.byType(CustomKeyboard), findsOneWidget);

    expect(CustomTVTextField.closeTopKeyboard(), isTrue);
    await _settle(tester);

    expect(find.byType(CustomKeyboard), findsNothing);
    expect(find.text('search results'), findsOneWidget);
    expect(controller.text, 'dune');
    expect(CustomTVTextField.closeTopKeyboard(), isFalse);
  });

  testWidgets('a disposed field stops claiming back', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<CustomTVTextFieldState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomTVTextField(
            key: fieldKey,
            controller: controller,
            popParentOnKeyboardClose: false,
          ),
        ),
      ),
    );

    fieldKey.currentState!.openKeyboard();
    await _settle(tester);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('somewhere else'))),
    );
    await _settle(tester);

    expect(CustomTVTextField.closeTopKeyboard(), isFalse);
  });

  testWidgets('tvOS native keyboard dismissal submits its final text once', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submissions = <String>[];
    final fieldKey = GlobalKey<CustomTVTextFieldState>();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleTvSystemChannel, (call) async {
          if (call.method == 'showTextInput') return true;
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomTVTextField(
            key: fieldKey,
            controller: controller,
            preferSystemIme: true,
            onFieldSubmitted: submissions.add,
          ),
        ),
      ),
    );

    fieldKey.currentState!.openKeyboard();
    await _settle(tester);

    final submittedCall = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('systemTextInputSubmitted', 'Friday watch party'),
    );
    unawaited(
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'moonfin/appletv_system',
        submittedCall,
        null,
      ),
    );
    await _settle(tester);

    expect(controller.text, 'Friday watch party');
    expect(submissions, ['Friday watch party']);
    expect(fieldKey.currentState!.isKeyboardVisible, isFalse);

    unawaited(
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'moonfin/appletv_system',
        submittedCall,
        null,
      ),
    );
    await _settle(tester);

    expect(submissions, ['Friday watch party']);
  });
}
