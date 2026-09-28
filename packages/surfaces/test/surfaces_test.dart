import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surfaces/surfaces.dart';

/// A shell that answers from a function, recording commands.
class _FakeShell extends SurfaceShell {
  _FakeShell(this.answer);

  final ExecResult Function(String command) answer;
  final commands = <String>[];

  @override
  Future<ExecResult> exec(
    String command, {
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    commands.add(command);
    return answer(command);
  }
}

class _Navigation extends SurfaceNavigation {
  var exits = 0;

  void back() => emitBack();

  @override
  Future<bool> exit() async {
    exits++;
    return true;
  }
}

void main() {
  test('shell quoting survives quotes and spaces', () {
    expect(shellQuote("it's here"), r"'it'\''s here'");
    expect(shellLine(['a b', 'c']), "'a b' 'c'");
  });

  test('ops decode results and errors', () async {
    final ops = Ops(FunctionOpsTransport(
      call: (request) {
        final op = (jsonDecode(request) as Map)['op'];
        return op == 'ok'
            ? '{"ok":{"n":1}}'
            : '{"error":{"code":"unknown-op","message":"no"}}';
      },
      start: (_) => '{"ok":{"id":"j1"}}',
      poll: (_) => '{"ok":{"id":"j1","op":"x","state":"done","progress":1,"result":42}}',
      cancel: (_) => '{"ok":{"id":"j1"}}',
    ), pollInterval: const Duration(milliseconds: 1));
    expect(await ops.call('ok'), {'n': 1});
    await expectLater(
      ops.call('nope'),
      throwsA(isA<OpsException>().having((e) => e.code, 'code', 'unknown-op')),
    );
    final job = await ops.start('x');
    final status = await job.done;
    expect(status.state, JobState.done);
    expect(status.result, 42);
  });

  test('unavailable ops and core say why', () {
    expect(
      () => Ops.unavailable('no worker').call('x'),
      throwsA(isA<OpsException>().having((e) => e.message, 'message', contains('no worker'))),
    );
    expect(Core.unavailable().available, isFalse);
  });

  test('worker transport speaks the worker command line', () async {
    final shell = _FakeShell((command) => ExecResult(0, 'noise\n{"ok":{"os":"android"}}\n', ''));
    final transport = WorkerTransport(shell: shell, worker: '/m/bin/worker', stateDir: '/t/jobs');
    expect(await Ops(transport).call('sys.info'), {'os': 'android'});
    final encoded = WorkerTransport.encode('{"op":"sys.info","input":null}');
    expect(shell.commands.single, "'/m/bin/worker' '--state' '/t/jobs' 'call' '$encoded'");
    expect(encoded.contains('='), isFalse);
    final broken = WorkerTransport(
      shell: _FakeShell((_) => const ExecResult(126, '', 'Permission denied')),
      worker: 'w',
      stateDir: 's',
    );
    await expectLater(
      Ops(broken).call('x'),
      throwsA(isA<OpsException>().having((e) => e.message, 'message', contains('Permission denied'))),
    );
  });

  test('core decodes JSON and bytes', () {
    final core = Core(FunctionCoreBinding(
      call: (_) => '{"ok":"hi"}',
      bytes: (_) => Uint8List.fromList([0, 1, 2]),
    ));
    expect(core.call('x'), 'hi');
    expect(core.bytes('x'), [1, 2]);
    final failing = Core(FunctionCoreBinding(
      call: (_) => '{"error":{"code":"input","message":"bad"}}',
      bytes: (_) => Uint8List.fromList([1, ...utf8.encode('{"error":{"code":"input","message":"bad"}}')]),
    ));
    expect(() => failing.call('x'), throwsA(isA<OpsException>()));
    expect(() => failing.bytes('x'), throwsA(isA<OpsException>()));
  });

  test('safe area joins MediaQuery padding', () {
    const data = MediaQueryData(viewInsets: EdgeInsets.only(bottom: 100));
    final merged = withSafeArea(data, const EdgeInsets.only(top: 24, bottom: 20));
    expect(merged.viewPadding, const EdgeInsets.only(top: 24, bottom: 20));
    expect(merged.padding, const EdgeInsets.only(top: 24));
  });

  testWidgets('host Back pops routes, then exits from the first page', (tester) async {
    final navigation = _Navigation();
    final surface = Surface(
      info: const HostInfo(kind: HostKind.webui, name: 'Test', capabilities: {Cap.exit}),
      config: const SurfaceConfig(appId: 'test'),
      navigation: navigation,
    );
    surface.window.safeArea.value = const EdgeInsets.only(top: 30);
    final navigator = GlobalKey<NavigatorState>();
    late EdgeInsets padding;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      builder: (context, child) => SurfaceScope(surface: surface, child: child!),
      home: Builder(builder: (context) {
        padding = MediaQuery.paddingOf(context);
        return const Text('home');
      }),
    ));
    expect(padding.top, 30);

    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('second')));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    // The popRoute goes through the real channel buffers, outside the
    // test's fake clock; let it land.
    Future<void> back() async {
      navigation.back();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    await back();
    expect(find.text('home'), findsOneWidget);
    expect(navigation.exits, 0);

    await back();
    expect(navigation.exits, 1);
  });

  testWidgets('toasts without a host toast show in the app', (tester) async {
    final surface = Surface(
      info: const HostInfo(kind: HostKind.browser, name: 'Test'),
      config: const SurfaceConfig(appId: 'test'),
    );
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => SurfaceScope(surface: surface, child: child!),
      home: const SizedBox(),
    ));
    unawaited(surface.feedback.toast('Saved'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  test('fallback surface on the VM keeps files and runs sh', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final surface = await Surface.init(const SurfaceConfig(appId: 'surfaces_test_app'));
    expect(surface.info.kind, anyOf(HostKind.desktop, HostKind.mobile));
    final result = await surface.shell.exec('echo hi');
    expect(result.stdout.trim(), 'hi');
    await surface.storage.writeText('note.txt', 'hello');
    expect(await surface.storage.readText('note.txt'), 'hello');
    await surface.storage.delete('note.txt');
    expect(await surface.storage.readText('note.txt'), isNull);
    expect(() => surface.storage.readText('../x'), throwsArgumentError);
  });
}
