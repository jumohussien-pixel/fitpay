import 'package:fitpay/services/fitpay_session_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native session snapshot maps goal progress', () {
    final snapshot = FitPaySessionSnapshot.fromMap({
      'active': true,
      'mode': 'squats',
      'goal': 10,
      'count': 4,
    });

    expect(snapshot.active, isTrue);
    expect(snapshot.mode, 'squats');
    expect(snapshot.goal, 10);
    expect(snapshot.count, 4);
  });

  test('native session snapshot supplies defaults for missing values', () {
    final snapshot = FitPaySessionSnapshot.fromMap(const <String, Object>{});

    expect(snapshot.active, isFalse);
    expect(snapshot.mode, 'steps');
    expect(snapshot.goal, 100);
    expect(snapshot.count, 0);
  });
}