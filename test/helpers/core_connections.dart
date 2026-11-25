import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:mocktail/mocktail.dart';

class MockCoreWithConnections extends Mock implements CoreHandlerInterface {
  @override
  Future<R> getConnectionsWith<R extends Object>(
    R Function(List<TrackerInfo>) present,
  ) async => present(await getConnections());
}
