/// Opt-in match pot helpers. Stake is peer-to-peer; `0` is free play.
library;

/// 1 NEAR in yoctoNEAR.
const nearYocto = '1000000000000000000000000';

/// 0.1 NEAR in yoctoNEAR (tests / examples).
const tenthNearYocto = '100000000000000000000000';

/// Same as `contracts/engkwentro` `RAKE_BPS` — 1.5% of the pot.
const rakeBps = 150;

/// Create-flow stake: per-player escrow as yocto + display label.
class StakeOption {
  /// [yocto] is attached on create/accept; [label] is for UI copy.
  const StakeOption({required this.label, required this.yocto});

  /// Human label (e.g. `Free`, `0.5 NEAR`).
  final String label;

  /// Deposit / `create_match.stake` as a decimal string.
  final String yocto;

  /// True when no NEAR is escrowed.
  bool get isFree => yocto == '0' || BigInt.parse(yocto) == BigInt.zero;
}

/// Create-flow choices: clock bank + optional stake.
class CreateMatchChoices {
  /// [clockMinutes] 1–15; [stake] is the per-player escrow.
  const CreateMatchChoices({
    required this.clockMinutes,
    required this.stake,
  });

  /// Per-player clock bank in minutes.
  final int clockMinutes;

  /// Stake each side attaches.
  final StakeOption stake;
}

/// Winner payout and protocol rake for a per-player [stakeYocto].
///
/// Matches `play::payout_amounts`: pot = 2 × stake, rake = pot × 150 / 10_000.
({BigInt winner, BigInt rake, BigInt pot}) payoutSplit(String stakeYocto) {
  final stake = BigInt.tryParse(stakeYocto) ?? BigInt.zero;
  if (stake == BigInt.zero) {
    return (winner: BigInt.zero, rake: BigInt.zero, pot: BigInt.zero);
  }
  final pot = stake * BigInt.two;
  final rake = pot * BigInt.from(rakeBps) ~/ BigInt.from(10000);
  return (winner: pot - rake, rake: rake, pot: pot);
}

/// Parses a NEAR amount typed in the create dialog into yoctoNEAR.
///
/// Accepts `0`, `1`, `0.1`, `.5`, up to 24 fractional digits. Empty → `0`.
/// Returns `null` when the text is not a non-negative decimal.
String? nearTextToYocto(String raw) {
  final t = raw.trim().replaceAll(',', '');
  if (t.isEmpty) return '0';
  if (!RegExp(r'^\d*\.?\d+$').hasMatch(t)) return null;
  final parts = t.split('.');
  if (parts.length > 2) return null;
  final whole = parts[0].isEmpty ? '0' : parts[0];
  var frac = parts.length == 2 ? parts[1] : '';
  if (frac.length > 24) return null;
  frac = frac.padRight(24, '0');
  final yocto = BigInt.parse(whole) * BigInt.parse(nearYocto) + BigInt.parse(frac);
  return yocto.toString();
}

/// Builds a [StakeOption] from typed NEAR text, or `null` if invalid.
StakeOption? stakeFromNearText(String raw) {
  final yocto = nearTextToYocto(raw);
  if (yocto == null) return null;
  final v = BigInt.parse(yocto);
  if (v == BigInt.zero) {
    return const StakeOption(label: 'Free', yocto: '0');
  }
  return StakeOption(label: formatNearYocto(yocto), yocto: yocto);
}

/// Formats a yocto amount for the match chrome (pot / stake line).
String formatNearYocto(String yocto) {
  final v = BigInt.tryParse(yocto) ?? BigInt.zero;
  if (v == BigInt.zero) return 'Free';
  final one = BigInt.parse(nearYocto);
  if (v % one == BigInt.zero) {
    return '${v ~/ one} NEAR';
  }
  final s = v.toString().padLeft(25, '0');
  final whole = s.substring(0, s.length - 24).replaceFirst(RegExp(r'^0+(?=.)'), '');
  var frac = s.substring(s.length - 24).replaceFirst(RegExp(r'0+$'), '');
  if (frac.isEmpty) return '$whole NEAR';
  if (frac.length > 6) frac = frac.substring(0, 6).replaceFirst(RegExp(r'0+$'), '');
  return '$whole.$frac NEAR';
}

/// `2 × stake` for the pot line.
String formatPotYocto(String stakeYocto) {
  final v = BigInt.tryParse(stakeYocto) ?? BigInt.zero;
  if (v == BigInt.zero) return 'Free match';
  return 'Pot ${formatNearYocto((v * BigInt.two).toString())}';
}

/// Sublabel under the stake field: winner take / protocol rake.
String stakePayoutCaption(String stakeYocto) {
  final split = payoutSplit(stakeYocto);
  if (split.pot == BigInt.zero) {
    return 'Setting 0 does not wager anything — free match, gas only.';
  }
  return 'Winner wins ${formatNearYocto(split.winner.toString())}. '
      'App takes ${formatNearYocto(split.rake.toString())} (1.5% rake).';
}
