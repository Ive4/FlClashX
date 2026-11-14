import 'package:fl_clash/common/application_history.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final applicationHistoryProvider = Provider<ApplicationHistory>(
  (ref) => applicationHistory,
);
