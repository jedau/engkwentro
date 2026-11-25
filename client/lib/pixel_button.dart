import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme.dart';

/// Style-B arcade block adapted to the Engkwentro palette.
enum PixelButtonVariant {
  /// Cream face, ink type, gold logo-style extrusion (Connect / Create).
  primary,

  /// Navy face, cream type/border (Join).
  secondary,
}

/// Full-width pixel CTA — solid face, notched corners, chunky border.
class PixelButton extends StatelessWidget {
  /// [label] is drawn in a compact pixel face.
  ///
  /// With [leading] and [trailingLabel], the face reads
  /// `LABEL · leading · TRAILING` (e.g. Connect · N · Wallet).
  /// With only [leading], the mark sits before [label].
  const PixelButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = PixelButtonVariant.primary,
    this.compact = false,
    this.leading,
    this.trailingLabel,
  });

  /// Button text (shown uppercase). Left half when [trailingLabel] is set.
  final String label;

  /// Null disables the control.
  final VoidCallback? onPressed;

  /// Primary cream vs secondary navy block.
  final PixelButtonVariant variant;

  /// Tighter padding for dialogs and toolbars.
  final bool compact;

  /// Optional mark (e.g. NEAR N) before [label], or between labels.
  final Widget? leading;

  /// Right half when [leading] sits between words (uppercase).
  final String? trailingLabel;

  bool get _enabled => onPressed != null;

  @override
  Widget build(BuildContext context) {
    final primary = variant == PixelButtonVariant.primary;
    // B-structure: solid face + dark rim. Theme: cream face (not loud gold),
    // gold only as the logo-style bottom-right extrusion.
    final face = primary ? EngkwentroColors.cream : EngkwentroColors.boardLight;
    final rim = primary ? EngkwentroColors.ink : EngkwentroColors.cream;
    final fg = primary ? EngkwentroColors.ink : EngkwentroColors.cream;
    final extrusion = primary ? EngkwentroColors.gold : EngkwentroColors.ink;

    final step = compact ? 3.0 : 4.0;
    final rimW = compact ? 3.0 : 4.0;
    final extrude = compact ? 3.0 : 4.0;
    final fontSize = compact ? 8.0 : 10.0;
    final padV = compact ? 12.0 : 16.0;
    final padH = compact ? 12.0 : 18.0;
    final iconSize = fontSize;
    final gap = compact ? 6.0 : 8.0;

    final textStyle = GoogleFonts.pressStart2p(
      fontSize: fontSize,
      height: leading != null ? 1.0 : 1.4,
      color: fg,
      letterSpacing: 0.4,
    );

    Widget labelText(String value) => Text(
      value.toUpperCase(),
      textAlign: TextAlign.center,
      style: textStyle,
    );

    // Baseline + small lift: image ink sits on the em floor while Press Start
    // caps sit above it on both Skia (Android) and CoreText (iOS).
    Widget mark({required bool padStart, required bool padEnd}) => Padding(
      padding: EdgeInsets.only(
        left: padStart ? gap : 0,
        right: padEnd ? gap : 0,
      ),
      child: Transform.translate(
        offset: const Offset(0, -1.3),
        child: Baseline(
          baseline: iconSize,
          baselineType: TextBaseline.alphabetic,
          child: SizedBox(width: iconSize, height: iconSize, child: leading),
        ),
      ),
    );

    final Widget child;
    if (leading != null && trailingLabel != null) {
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        mainAxisSize: MainAxisSize.min,
        children: [
          labelText(label),
          mark(padStart: true, padEnd: true),
          labelText(trailingLabel!),
        ],
      );
    } else if (leading != null) {
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        mainAxisSize: MainAxisSize.min,
        children: [mark(padStart: false, padEnd: true), labelText(label)],
      );
    } else {
      child = labelText(label);
    }

    return Opacity(
      opacity: _enabled ? 1 : 0.45,
      child: Padding(
        // Room for the gold/ink extrusion under the hit target.
        padding: EdgeInsets.only(right: extrude, bottom: extrude),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            splashColor: Colors.transparent,
            highlightColor: EngkwentroColors.sand.withValues(alpha: 0.2),
            child: CustomPaint(
              painter: PixelNotchPainter(
                face: face,
                rim: rim,
                extrusion: extrusion,
                step: step,
                rimWidth: rimW,
                extrude: extrude,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: padV, horizontal: padH),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary arcade action (Cancel, Resign, Export) — no extrusion block.
class PixelTextButton extends StatelessWidget {
  /// Gold Press Start label; uppercase.
  const PixelTextButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  /// Button text.
  final String label;

  /// Null disables.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(onPressed: onPressed, child: Text(label.toUpperCase()));
  }
}

/// Notched panel for keys, banners, activity chrome, wallet tiles.
class PixelPanel extends StatelessWidget {
  /// [child] sits on a Style-B face with optional gold extrusion.
  const PixelPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.primary = false,
  });

  /// Panel contents.
  final Widget child;

  /// Inner padding.
  final EdgeInsetsGeometry padding;

  /// Cream face + gold extrusion when true; navy face otherwise.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    const step = 4.0;
    const rimW = 3.0;
    const extrude = 3.0;
    final face = primary ? EngkwentroColors.cream : EngkwentroColors.boardLight;
    final rim = primary ? EngkwentroColors.ink : EngkwentroColors.cream;
    final extrusion = primary ? EngkwentroColors.gold : EngkwentroColors.ink;

    return Padding(
      padding: const EdgeInsets.only(right: extrude, bottom: extrude),
      child: CustomPaint(
        painter: PixelNotchPainter(
          face: face,
          rim: rim,
          extrusion: extrusion,
          step: step,
          rimWidth: rimW,
          extrude: extrude,
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Draws a notched rectangle: extrusion → rim → face (Style B silhouette).
class PixelNotchPainter extends CustomPainter {
  /// Shared painter for [PixelButton] and [PixelPanel].
  PixelNotchPainter({
    required this.face,
    required this.rim,
    required this.extrusion,
    required this.step,
    required this.rimWidth,
    required this.extrude,
  });

  final Color face;
  final Color rim;
  final Color extrusion;
  final double step;
  final double rimWidth;
  final double extrude;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Size(size.width, size.height);
    final s1 = (step - 1).clamp(2, step).toDouble();

    final shadowPath = _notchedRect(
      Rect.fromLTWH(extrude, extrude, body.width, body.height),
      step,
    );
    canvas.drawPath(shadowPath, Paint()..color = extrusion);

    final rimPath = _notchedRect(
      Rect.fromLTWH(0, 0, body.width, body.height),
      step,
    );
    canvas.drawPath(rimPath, Paint()..color = rim);

    final facePath = _notchedRect(
      Rect.fromLTWH(
        rimWidth,
        rimWidth,
        body.width - rimWidth * 2,
        body.height - rimWidth * 2,
      ),
      s1,
    );
    canvas.drawPath(facePath, Paint()..color = face);
  }

  /// Axis-aligned rect with one-step notched corners (pixel cutouts).
  Path _notchedRect(Rect r, double s) {
    final left = r.left;
    final top = r.top;
    final right = r.right;
    final bottom = r.bottom;
    return Path()
      ..moveTo(left + s, top)
      ..lineTo(right - s, top)
      ..lineTo(right - s, top + s)
      ..lineTo(right, top + s)
      ..lineTo(right, bottom - s)
      ..lineTo(right - s, bottom - s)
      ..lineTo(right - s, bottom)
      ..lineTo(left + s, bottom)
      ..lineTo(left + s, bottom - s)
      ..lineTo(left, bottom - s)
      ..lineTo(left, top + s)
      ..lineTo(left + s, top + s)
      ..close();
  }

  @override
  bool shouldRepaint(covariant PixelNotchPainter old) =>
      face != old.face ||
      rim != old.rim ||
      extrusion != old.extrusion ||
      step != old.step ||
      rimWidth != old.rimWidth ||
      extrude != old.extrude;
}
