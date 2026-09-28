import 'dart:io';

import 'package:surfaces_cli/surfaces_cli.dart';
import 'package:test/test.dart';

void main() {
  test('reads surfaces.yaml and fills module templates', () {
    final dir = Directory.systemTemp.createTempSync('surfaces_cli');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/surfaces.yaml').writeAsStringSync('''
id: my_app
name: My App
version: 1.2.3
author: me
description: Does things.
rust:
  core: app_core
''');
    final app = AppConfig.load(dir.path);
    expect(app.versionCode, 10203);
    expect(app.coreCrate, 'app_core');
    expect(app.workerCrate, isNull);
    expect(app.fill('id=@ID@ v@VERSION@ (@VERSION_CODE@) @WORKER@'), 'id=my_app v1.2.3 (10203) worker');
  });

  test('rejects a bad module id', () {
    final dir = Directory.systemTemp.createTempSync('surfaces_cli');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/surfaces.yaml').writeAsStringSync('id: 9lives\n');
    expect(() => AppConfig.load(dir.path), throwsA(isA<UsageError>()));
  });
}
