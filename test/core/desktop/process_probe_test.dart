import 'dart:io';

import 'package:fl_clash/core/desktop/process_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a live PID must also belong to the expected executable', () async {
    expect(
      await isProcessExecutableAlive(pid, Platform.resolvedExecutable),
      isTrue,
    );
    expect(
      await isProcessExecutableAlive(
        pid,
        '${Platform.resolvedExecutable}.other',
      ),
      isFalse,
    );
  });
}
