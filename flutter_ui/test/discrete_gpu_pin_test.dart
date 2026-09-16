// The discrete card pin, on Windows.
//
// A laptop with two graphics cards gives a process the integrated one by
// default. Flutter draws through ANGLE on that card, the engine asks wgpu for
// the high performance one and gets the discrete card, and the shared texture
// the Viewer rides on will not open across two cards. The picture goes black
// and the audio carries on, which is what 0.4.0 shipped with.
//
// The fix is two values exported from Lumit.exe that the Nvidia and AMD
// drivers read at startup. They only work from the executable, so there is
// nothing for a Dart test to call, and this reads the runner's source instead.
// Same trick as skia_pin_test.dart, and the only check that fails the day the
// exports are dropped or zeroed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Test working directory is flutter_ui/.
  final runner = File('windows/runner/main.cpp').readAsStringSync();

  test('the Windows runner asks both drivers for the discrete card', () {
    // The value has to be non-zero, and 0 is the same as not being there at
    // all, so the zero case is named rather than left to a contains().
    final nvidia = RegExp(
        r'dllexport\)?\s+DWORD\s+NvOptimusEnablement\s*=\s*(0x0*[1-9a-fA-F][0-9a-fA-F]*|[1-9]\d*)');
    final amd = RegExp(
        r'dllexport\)?\s+int\s+AmdPowerXpressRequestHighPerformance\s*=\s*(0x0*[1-9a-fA-F][0-9a-fA-F]*|[1-9]\d*)');
    expect(nvidia.hasMatch(runner), isTrue,
        reason: 'NvOptimusEnablement must be exported and non-zero, or an '
            'Optimus laptop draws the Viewer on the integrated card');
    expect(amd.hasMatch(runner), isTrue,
        reason: 'AmdPowerXpressRequestHighPerformance must be exported and '
            'non-zero, for the same reason on a Radeon laptop');
  });

  test('the exports keep their C names', () {
    // C++ would mangle them and the driver would never find them, so the block
    // they sit in matters as much as the values.
    final block = RegExp(
        r'extern\s+"C"\s*\{[^}]*NvOptimusEnablement[^}]*AmdPowerXpressRequestHighPerformance[^}]*\}');
    expect(block.hasMatch(runner), isTrue,
        reason: 'both exports belong in one extern "C" block, or the driver '
            'looks for a name that is not in the export table');
  });
}
