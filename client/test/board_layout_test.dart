import 'package:engkwentro/board_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// [snugBoardSize] width-first and height-limited cases.
void main() {
  test('portrait phone uses full width and 8/9 height', () {
    final size = snugBoardSize(
      const BoxConstraints.tightFor(width: 390, height: 700),
    );
    expect(size.width, 390);
    expect(size.height, closeTo(390 * 8 / 9, 0.01));
  });

  test('short leftover shrinks width to keep square cells', () {
    final size = snugBoardSize(
      const BoxConstraints.tightFor(width: 390, height: 200),
    );
    expect(size.height, 200);
    expect(size.width, closeTo(200 * 9 / 8, 0.01));
  });

  test('display ranks put each side on the bottom half', () {
    expect(displayBoardRank(0, sideA: true), 7);
    expect(displayBoardRank(7, sideA: true), 0);
    expect(displayBoardRank(0, sideA: false), 0);
    expect(displayBoardRank(7, sideA: false), 7);
  });

  test('display files mirror for side B (180°)', () {
    expect(displayBoardFile(0, sideA: true), 0);
    expect(displayBoardFile(2, sideA: true), 2);
    expect(displayBoardFile(0, sideA: false), 8);
    expect(displayBoardFile(2, sideA: false), 6);
  });
}
