import 'package:engkwentro/join_key.dart';
import 'package:flutter_test/flutter_test.dart';

/// [normalizeJoinKey] and [formatJoinKey].
void main() {
  test('normalize strips grouping and lower case', () {
    expect(normalizeJoinKey('ab2c-de3f-gh4j'), 'AB2CDE3FGH4J');
    expect(isJoinKey('ab2c-de3f-gh4j'), isTrue);
    expect(isJoinKey('6'), isFalse);
  });

  test('format groups twelve characters', () {
    expect(formatJoinKey('K7M2P9QWX4R8'), 'K7M2-P9QW-X4R8');
  });
}
