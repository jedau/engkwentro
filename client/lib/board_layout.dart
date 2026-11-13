import 'package:flutter/widgets.dart';

/// Largest 9×8 board of square cells that fits [box], width-first like chess.com.
///
/// Tries full width first. If the resulting height overflows [box.maxHeight],
/// shrinks so both axes fit. [files] and [ranks] default to the Generals board.
Size snugBoardSize(BoxConstraints box, {int files = 9, int ranks = 8}) {
  final maxW = box.maxWidth;
  final maxH = box.maxHeight.isFinite ? box.maxHeight : maxW * ranks / files;
  var width = maxW;
  var height = width * ranks / files;
  if (height > maxH) {
    height = maxH;
    width = height * files / ranks;
  }
  return Size(width, height);
}

/// Wire `board_rank` for a grid row counted from the top of the phone.
///
/// Side A keeps rank 7 at the top (own home 0–2 at the bottom). Side B flips
/// so their home 5–7 sits at the bottom. Always “me on the lower half.”
int displayBoardRank(int rowFromTop, {required bool sideA}) =>
    sideA ? 7 - rowFromTop : rowFromTop;

/// Wire `file` for a grid column counted from the left of the phone.
///
/// Side B is a 180° view: file 0 is on their right, so Alice's columns 1–3
/// (Bob's forward three) land on Alice's 7–8–9 when Bob places on his left.
int displayBoardFile(int colFromLeft, {required bool sideA}) =>
    sideA ? colFromLeft : 8 - colFromLeft;
