import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/features/files/device_files.dart';

import 'widget_test.dart';

/// This device's side of a copy on a phone, recorded instead of done.
class FakeDeviceFiles extends DeviceFiles {
  FakeDeviceFiles({this.savesWithDialog = false});

  @override
  final bool savesWithDialog;

  List<PickedFile> picks = const [];
  String? saveTo;
  final List<String> calls = [];
  int _scratch = 0;

  @override
  Future<List<PickedFile>> pick() async {
    calls.add('pick');
    return picks;
  }

  @override
  Future<String?> saveLocation(String name) async {
    calls.add('save as $name');
    return saveTo;
  }

  @override
  Future<String> scratchPath(String name) async => '/cache/${++_scratch}/$name';

  @override
  Future<void> share(String path, {Rect? origin}) async => calls.add('share $path');

  @override
  Future<void> open(String path, {Rect? origin}) async => calls.add('open $path');
}

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 760);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> openFiles(WidgetTester tester, FakeEngine engine, FakeDeviceFiles device) async {
  engine.connectedSessionId = 7;
  engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
  await tester.pumpWidget(appWith(engine, deviceFiles: device));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('host-row-h1')));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('session-files')));
  await tester.pumpAndSettle();
}

Future<void> entryAction(WidgetTester tester, String name, String action) async {
  await tester.tap(find.byKey(Key('entry-menu-$name')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('on a phone, files picked on the device upload into the folder on show', (tester) async {
    phone(tester);
    final engine = FakeEngine();
    final device = FakeDeviceFiles()
      ..picks = const [
        (path: '/picked/report.pdf', name: 'report.pdf'),
        (path: '/picked/notes.txt', name: 'notes.txt'),
      ];
    await openFiles(tester, engine, device);
    expect(find.byKey(const Key('local-pane')), findsNothing, reason: 'one pane');

    await tester.tap(find.byKey(const Key('remote-upload')));
    await tester.pumpAndSettle();
    expect(find.text('Replace notes.txt?'), findsOneWidget, reason: 'the server already has one');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.where((c) => c.startsWith('upload')), isEmpty, reason: 'nothing is sent on Cancel');

    await tester.tap(find.byKey(const Key('remote-upload')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('files-replace-ok')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.where((c) => c.startsWith('upload')), [
      'upload /picked/report.pdf /home/ops/report.pdf',
      'upload /picked/notes.txt /home/ops/notes.txt',
    ]);
    expect(find.text('Transfers'), findsOneWidget);
    expect(find.text('Done · 10 B'), findsNWidgets(2));
  });

  testWidgets('an upload in progress shows how far it has got and can be cancelled', (tester) async {
    phone(tester);
    final engine = FakeEngine()..finishTransfers = false;
    final device = FakeDeviceFiles()..picks = const [(path: '/picked/big.iso', name: 'big.iso')];
    await openFiles(tester, engine, device);
    await tester.tap(find.byKey(const Key('remote-upload')));
    await tester.pump();
    await tester.pump();
    expect(find.text('0 B of 10 B'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel upload of big.iso'));
    await tester.pump();
    expect(engine.fileCalls.last, 'cancel 1');
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.byTooltip('Cancel upload of big.iso'), findsNothing, reason: 'nothing left to cancel');
    await tester.tap(find.text('Clear finished'));
    await tester.pump();
    expect(find.text('Transfers'), findsNothing);
  });

  testWidgets('on a phone a download is fetched, then offered to save or send', (tester) async {
    phone(tester);
    final engine = FakeEngine()..finishTransfers = false;
    final device = FakeDeviceFiles();
    await openFiles(tester, engine, device);

    await entryAction(tester, 'notes.txt', 'Download to this device');
    expect(engine.fileCalls.last, 'download /home/ops/notes.txt /cache/1/notes.txt');
    expect(device.calls, isEmpty, reason: 'not shared until it has all arrived');

    engine.finishAll();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(device.calls, ['share /cache/1/notes.txt']);
    expect(find.text('Done · 2.0 KB'), findsOneWidget);
  });

  testWidgets('"Open in another app" fetches the file and hands it on, unless cancelled', (tester) async {
    phone(tester);
    final engine = FakeEngine()..finishTransfers = false;
    final device = FakeDeviceFiles();
    await openFiles(tester, engine, device);

    await entryAction(tester, 'notes.txt', 'Open in another app');
    expect(engine.fileCalls.last, 'download /home/ops/notes.txt /cache/1/notes.txt');
    await tester.tap(find.byTooltip('Cancel download of notes.txt'));
    await tester.pump();
    engine.finishAll();
    await tester.pump(const Duration(milliseconds: 400));
    expect(device.calls, isEmpty, reason: 'a cancelled download opens nothing');

    engine.finishTransfers = true;
    await entryAction(tester, 'notes.txt', 'Open in another app');
    await tester.pump();
    expect(device.calls, ['open /cache/2/notes.txt']);
  });

  testWidgets('a narrow window on a computer saves a download where the save dialog says', (tester) async {
    phone(tester);
    final engine = FakeEngine();
    final device = FakeDeviceFiles(savesWithDialog: true)..saveTo = '/home/me/Downloads/notes.txt';
    await openFiles(tester, engine, device);
    await entryAction(tester, 'notes.txt', 'Download to this device');
    await tester.pump();
    expect(device.calls, ['save as notes.txt'], reason: 'no share sheet');
    expect(engine.fileCalls.last, 'download /home/ops/notes.txt /home/me/Downloads/notes.txt');

    // Cancelling the dialog downloads nothing.
    device.saveTo = null;
    await entryAction(tester, 'notes.txt', 'Download to this device');
    await tester.pump();
    expect(engine.fileCalls.where((c) => c.startsWith('download')), hasLength(1));
  });

  testWidgets('the phone file browser and its transfers fit at double text size', (tester) async {
    phone(tester);
    final engine = FakeEngine()..finishTransfers = false;
    final device = FakeDeviceFiles()
      ..picks = const [
        (path: '/picked/a-rather-long-file-name-for-a-phone.tar.gz', name: 'a-rather-long-file-name-for-a-phone.tar.gz'),
      ];
    await openFiles(tester, engine, device);
    // Large text from here, on this screen only.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    await tester.tap(find.byKey(const Key('remote-upload')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('transfer-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('entry-menu-notes.txt')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open in another app'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
