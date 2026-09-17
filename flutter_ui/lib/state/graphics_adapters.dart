// Which graphics card the interface draws on, and whether it is the engine's.
//
// In plain terms: the engine draws the Viewer's picture on one graphics card and
// hands it to the interface as a piece of that card's memory. The interface can
// only show it if it is drawing on the same card. On a laptop with both an
// integrated and a dedicated card the two can end up on different ones, and then
// the Viewer stays empty without any error anywhere.
//
// The engine names its card through the bridge (`graphicsAdapters`); the Windows
// runner names the interface's card over the `lumit/graphics_adapter` channel.
// This file compares the two. The comparison itself is plain data in, answer out,
// so it is tested without an engine or a window.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../src/rust/api/system.dart';
import 'faults.dart';

/// The card the interface draws on, as the Windows runner reports it.
class InterfaceAdapter {
  const InterfaceAdapter({
    required this.name,
    required this.vendorId,
    required this.deviceId,
  });

  final String name;
  final int vendorId;
  final int deviceId;

  /// Read the runner's reply, or null when it is not the shape the runner sends
  /// — an old runner, another platform, an embedder that would not say.
  static InterfaceAdapter? fromChannel(Object? reply) {
    if (reply is! Map) return null;
    final name = reply['name'];
    final vendor = reply['vendorId'];
    final device = reply['deviceId'];
    if (name is! String || vendor is! int || device is! int) return null;
    return InterfaceAdapter(name: name, vendorId: vendor, deviceId: device);
  }
}

/// Whether the engine and the interface are drawing on the same card.
enum AdapterAgreement {
  /// The same card: the Viewer's texture can be opened.
  same,

  /// Different cards: the Viewer cannot show the engine's picture.
  different,

  /// One side would not say, or this platform does not hand pictures across
  /// cards in a way this check describes.
  unknown,
}

/// Compare the engine's card with the interface's, by PCI vendor and device.
///
/// By id rather than by name: the two sides read their names from different
/// APIs, and one driver's "NVIDIA GeForce RTX 4060 Laptop GPU" is another's
/// with different spacing. Two identical cards in one machine share both ids;
/// that is the one case this cannot split, and the one case it does not need to.
AdapterAgreement adapterAgreement({
  required ({int vendorId, int deviceId})? engine,
  required ({int vendorId, int deviceId})? ui,
}) {
  if (engine == null || ui == null) return AdapterAgreement.unknown;
  return engine.vendorId == ui.vendorId && engine.deviceId == ui.deviceId
      ? AdapterAgreement.same
      : AdapterAgreement.different;
}

/// The engine's own card out of the bridge's list, or null when none is marked.
BridgeGraphicsAdapter? engineAdapterOf(List<BridgeGraphicsAdapter> adapters) {
  for (final adapter in adapters) {
    if (adapter.engine) return adapter;
  }
  return null;
}

/// The channel the Windows runner answers on
/// (`windows/runner/viewer_texture_bridge.cpp`).
const MethodChannel graphicsAdapterChannel =
    MethodChannel('lumit/graphics_adapter');

/// Ask the runner which card the interface draws on. Null anywhere it cannot
/// answer: off Windows (no runner implements the channel), or an embedder that
/// would not say.
Future<InterfaceAdapter?> interfaceAdapter({
  MethodChannel channel = graphicsAdapterChannel,
}) async {
  try {
    return InterfaceAdapter.fromChannel(
        await channel.invokeMethod<Object?>('interfaceAdapter'));
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Everything the Settings readout shows, in one read.
typedef GraphicsAdapterReport = ({
  List<BridgeGraphicsAdapter> engine,
  InterfaceAdapter? ui,
  AdapterAgreement agreement,
});

/// Read both sides and compare them.
///
/// Never throws: a readout that can break the page it sits on is worse than a
/// readout that says "not known here".
Future<GraphicsAdapterReport> readGraphicsAdapters() async {
  List<BridgeGraphicsAdapter> adapters;
  try {
    adapters = await graphicsAdapters();
  } catch (_) {
    adapters = const [];
  }
  final ui = await interfaceAdapter();
  final engine = engineAdapterOf(adapters);
  return (
    engine: adapters,
    ui: ui,
    agreement: adapterAgreement(
      engine: engine == null
          ? null
          : (vendorId: engine.vendorId, deviceId: engine.deviceId),
      ui: ui == null ? null : (vendorId: ui.vendorId, deviceId: ui.deviceId),
    ),
  );
}

bool _checked = false;

/// Once a session, when the Viewer first has a texture: if the two sides are
/// on different cards, write both names to the diagnostics file and say so.
///
/// **Windows only.** The shared-handle hand-off this describes is the Windows
/// one; the Linux and macOS paths import on their own terms, and a comparison
/// that means nothing there should not be made there.
///
/// Why at the first texture and not at start-up: before a renderer exists the
/// engine's card is a prediction, and the interface's device may not have been
/// created yet. By the time a texture is registered, both are real.
Future<void> checkGraphicsAdaptersOnce({
  required void Function(InterfaceAdapter ui, BridgeGraphicsAdapter engine)
      onDifferent,
}) async {
  if (_checked || !Platform.isWindows) return;
  _checked = true;
  // The runner first: without its answer there is nothing to compare, and the
  // engine need not be asked to enumerate adapters for nothing.
  final ui = await interfaceAdapter();
  if (ui == null) return;
  List<BridgeGraphicsAdapter> adapters;
  try {
    adapters = await graphicsAdapters();
  } catch (_) {
    return;
  }
  final engine = engineAdapterOf(adapters);
  if (engine == null) return;
  final agreement = adapterAgreement(
    engine: (vendorId: engine.vendorId, deviceId: engine.deviceId),
    ui: (vendorId: ui.vendorId, deviceId: ui.deviceId),
  );
  if (agreement != AdapterAgreement.different) return;
  recordFault(
      'the engine draws on "${engine.name}" '
      '(${_hex(engine.vendorId)}:${_hex(engine.deviceId)}) and the interface on '
      '"${ui.name}" (${_hex(ui.vendorId)}:${_hex(ui.deviceId)}) — a Viewer '
      'texture cannot cross between cards, so the Viewer will stay empty',
      StackTrace.current);
  onDifferent(ui, engine);
}

String _hex(int id) => id.toRadixString(16).padLeft(4, '0');
