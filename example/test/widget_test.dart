// Smoke test for the mic_recorder example app.
//
// The app title matters: the demo keeps the exact 'mic_recorder example'
// AppBar text this test verifies.

import 'package:flutter_test/flutter_test.dart';
import 'package:mic_recorder_example/main.dart';

void main() {
  testWidgets('renders the mic_recorder example title', (tester) async {
    // Build the widget tree inside testWidgets with a locally initialized
    // binding so the tree runs in the test zone.
    TestWidgetsFlutterBinding.ensureInitialized();

    await tester.pumpWidget(const MicRecorderExampleApp());

    expect(find.text('mic_recorder example'), findsOneWidget);

    // initState calls MicRecorder.instance.initialize(), which arms
    // AppLifecycleTracker's one-shot 100 ms assume-resumed priming timer.
    // Pump 200 ms so the timer fires — otherwise the test framework fails
    // with "A Timer is still pending".
    await tester.pump(const Duration(milliseconds: 200));
  });
}
