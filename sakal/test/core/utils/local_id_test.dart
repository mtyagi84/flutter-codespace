import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/utils/local_id.dart';

void main() {
  group('generateLocalId', () {
    test('always starts with the LOCAL- prefix SyncEngine and the local Drift cache key on', () {
      expect(generateLocalId(), startsWith('LOCAL-'));
    });

    test('matches the documented shape LOCAL-<timestamp>-<6 random lowercase-alnum chars>', () {
      final id = generateLocalId();
      final match = RegExp(r'^LOCAL-(\d+)-([a-z0-9]{6})$').firstMatch(id);
      expect(match, isNotNull, reason: 'generated id "$id" does not match the expected shape');
    });

    test('embedded timestamp is a plausible millisecondsSinceEpoch value (close to now)', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final id = generateLocalId();
      final after = DateTime.now().millisecondsSinceEpoch;
      final ts = int.parse(id.split('-')[1]);
      expect(ts, greaterThanOrEqualTo(before));
      expect(ts, lessThanOrEqualTo(after));
    });

    test('consecutive calls produce different ids (never collide within a test run)', () {
      final ids = List.generate(200, (_) => generateLocalId());
      expect(ids.toSet().length, 200);
    });
  });
}
