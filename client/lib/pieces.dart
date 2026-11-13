import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'arbiter.g.dart';

/// SVG stem under `assets/images/pieces/{light|dark}/`.
const _rankStem = <Rank, String>{
  Rank.flag: 'flag',
  Rank.spy: 'spy',
  Rank.private: 'private',
  Rank.sergeant: 'sergeant',
  Rank.secondLieutenant: '2nd_lt',
  Rank.firstLieutenant: '1st_lt',
  Rank.captain: 'captain',
  Rank.major: 'major',
  Rank.lieutenantColonel: 'lt_colonel',
  Rank.colonel: 'colonel',
  Rank.brigadierGeneral: '1_star_general',
  Rank.majorGeneral: '2_star_general',
  Rank.lieutenantGeneral: '3_star_general',
  Rank.general: '4_star_general',
  Rank.fiveStarGeneral: '5_star_general',
};

/// Asset path for [rank], or the fog disc when [rank] is null.
///
/// [light] true → cream set (first mover); false → dark set (second).
String pieceAssetPath({Rank? rank, required bool light}) {
  final folder = light ? 'light' : 'dark';
  final stem = rank == null ? 'hidden' : _rankStem[rank]!;
  return 'assets/images/pieces/$folder/$stem.svg';
}

/// Renders a piece SVG. Pass [size] for a fixed box, or omit to fill the parent.
class PieceArt extends StatelessWidget {
  /// [rank] null paints the hidden enemy disc art.
  const PieceArt({
    super.key,
    required this.rank,
    required this.light,
    this.size,
  });

  /// Known rank, or null for fog.
  final Rank? rank;

  /// True → light (first mover) set; false → dark (second) set.
  final bool light;

  /// Edge length in logical pixels. Null → expand to parent constraints.
  final double? size;

  @override
  Widget build(BuildContext context) {
    if (size != null) {
      return SvgPicture.asset(
        pieceAssetPath(rank: rank, light: light),
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final edge = box.biggest.shortestSide;
        return SvgPicture.asset(
          pieceAssetPath(rank: rank, light: light),
          width: edge,
          height: edge,
          fit: BoxFit.contain,
        );
      },
    );
  }
}
