// The same-card check: the engine's graphics card against the interface's.
//
// Pure data in, answer out, plus the channel read with a mocked runner — no
// engine and no window, so it runs in the ordinary `flutter test` pass.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/state/graphics_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('adapterAgreement', () {
    const intel = (vendorId: 0x8086, deviceId: 0xa7a0);
    const nvidia = (vendorId: 0x10de, deviceId: 0x28e0);

    test('the same card agrees', () {
      expect(adapterAgreement(engine: intel, ui: intel), AdapterAgreement.same);
    });

    test('a laptop split across two cards is caught', () {
      // The report that started this: the engine on the dedicated card, the
      // interface on the integrated one, and an empty Viewer.
      expect(adapterAgreement(engine: nvidia, ui: intel),
          AdapterAgreement.different);
    });

    test('the same vendor with a different device is a different card', () {
      expect(
          adapterAgreement(
              engine: intel, ui: (vendorId: 0x8086, deviceId: 0x46a6)),
          AdapterAgreement.different);
    });

    test('a side that would not answer is unknown, never a mismatch', () {
      // Calling a missing answer "different" would tell a user on Linux or
      // macOS to change a Windows setting they do not have.
      expect(adapterAgreement(engine: intel, ui: null),
          AdapterAgreement.unknown);
      expect(adapterAgreement(engine: null, ui: intel),
          AdapterAgreement.unknown);
      expect(
          adapterAgreement(engine: null, ui: null), AdapterAgreement.unknown);
    });
  });

  group('InterfaceAdapter.fromChannel', () {
    test('reads the runner\'s reply', () {
      final a = InterfaceAdapter.fromChannel({
        'name': 'Intel(R) UHD Graphics',
        'vendorId': 0x8086,
        'deviceId': 0xa7a0,
        'luid': 12345,
        'dedicatedVideoMemory': 134217728,
      });
      expect(a, isNotNull);
      expect(a!.name, 'Intel(R) UHD Graphics');
      expect((a.vendorId, a.deviceId), (0x8086, 0xa7a0));
    });

    test('anything else is no answer rather than a wrong one', () {
      expect(InterfaceAdapter.fromChannel(null), isNull);
      expect(InterfaceAdapter.fromChannel('Intel'), isNull);
      expect(InterfaceAdapter.fromChannel({'name': 'Intel'}), isNull);
      expect(
          InterfaceAdapter.fromChannel(
              {'name': 'Intel', 'vendorId': '8086', 'deviceId': 1}),
          isNull);
    });
  });

  group('interfaceAdapter', () {
    const channel = MethodChannel('test/graphics_adapter');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('asks the runner by name', () async {
      String? asked;
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked = call.method;
        return {'name': 'Card', 'vendorId': 1, 'deviceId': 2};
      });
      final a = await interfaceAdapter(channel: channel);
      expect(asked, 'interfaceAdapter');
      expect(a?.name, 'Card');
    });

    test('a runner without the channel answers null, not an exception',
        () async {
      // No handler installed: the platform side reports a missing plugin, which
      // is exactly what Linux and macOS will do.
      expect(await interfaceAdapter(channel: channel), isNull);
    });

    test('a runner that refuses answers null', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'nope');
      });
      expect(await interfaceAdapter(channel: channel), isNull);
    });
  });
}
