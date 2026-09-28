import 'package:aera_flutter/aera_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AeraSystem.channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  testWidgets('reports whether the navigator can go back', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => AeraScope(child: child!),
        home: const Text('home'),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('page')),
    );
    await tester.pumpAndSettle();
    expect(calls.last.method, 'setNavigationState');
    expect(calls.last.arguments, {'canGoBack': true});

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calls.last.arguments, {'canGoBack': false});
  });

  test('top bar events and keyboard state reach the app', () async {
    final system = AeraSystem.instance;
    final opened = system.onOpen.first;
    await system.debugReceive(const MethodCall('onOpen', 'https://a.org'));
    expect(await opened, 'https://a.org');
    await system.debugReceive(
      const MethodCall('onKeyboard', {'visible': true, 'inset': 589.0}),
    );
    expect(system.keyboardVisible.value, isTrue);
  });

  test('status calls leave out what is not given', () async {
    await AeraSystem.instance.setStatus(progress: 40);
    expect(calls.single.arguments, {'progress': 40});
  });
}
