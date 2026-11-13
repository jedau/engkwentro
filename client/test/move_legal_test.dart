import 'package:engkwentro/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orthogonal one-step only', () {
    final a = MatchGame.sq(4, 3);
    expect(MatchGame.isOrthogonalStep(a, MatchGame.sq(4, 4)), isTrue);
    expect(MatchGame.isOrthogonalStep(a, MatchGame.sq(5, 3)), isTrue);
    expect(MatchGame.isOrthogonalStep(a, MatchGame.sq(4, 5)), isFalse);
    expect(MatchGame.isOrthogonalStep(a, MatchGame.sq(5, 4)), isFalse);
    expect(MatchGame.isOrthogonalStep(a, a), isFalse);
  });

  test('file wrap is not a step', () {
    // Square 8 (file 8) +1 would be next rank file 0 — not orthogonal.
    expect(MatchGame.isOrthogonalStep(8, 9), isFalse);
  });
}
