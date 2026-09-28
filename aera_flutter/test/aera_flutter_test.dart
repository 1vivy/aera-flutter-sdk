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
          if (call.method == 'getState') {
            return {
              'keyboardVisible': false,
              'padding': [0, 0, 0, 75.0],
              'gestureInsets': [37.5, 0, 37.5, 60.0],
            };
          }
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

  testWidgets('safe area reaches MediaQuery', (tester) async {
    late MediaQueryData seen;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 3),
        child: AeraScope(
          child: Builder(
            builder: (context) {
              seen = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(seen.padding, const EdgeInsets.only(bottom: 25));
    expect(seen.viewPadding.bottom, 25);
    expect(
      seen.systemGestureInsets,
      const EdgeInsets.fromLTRB(12.5, 0, 12.5, 20),
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          devicePixelRatio: 3,
          viewInsets: EdgeInsets.only(bottom: 196),
        ),
        child: AeraScope(
          child: Builder(
            builder: (context) {
              seen = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(seen.padding.bottom, 0);
    expect(seen.viewPadding.bottom, 25);
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

  test('recovery calls decode the embedder\'s replies', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AeraRecovery.channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getTheme' => {
              'accent': 0x16c8ff,
              'light': false,
              'interfaceSize': 'normal',
              'clock24': true,
            },
            'getBattery' => {'level': 87, 'temperatureC': 31.2},
            _ => null,
          };
        });
    final theme = await AeraRecovery.theme();
    expect(theme.accent, const Color(0xff16c8ff));
    expect(theme.brightness, Brightness.dark);
    expect((await AeraRecovery.battery()).level, 87);
    await AeraRecovery.reboot(RebootTarget.bootloader);
    expect(calls.last.arguments, 'bootloader');
  });
}
