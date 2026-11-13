// CLI tool stdout.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:engkwentro/mailbox.dart';
import 'package:engkwentro/near.dart';
import 'package:engkwentro/net_play.dart';
import 'package:engkwentro/ot.dart';

/// Loads `~/.near-credentials/testnet/{account}.json`.
Map<String, dynamic> cred(String account) {
  final home = Platform.environment['HOME']!;
  return jsonDecode(
    File('$home/.near-credentials/testnet/$account.json').readAsStringSync(),
  ) as Map<String, dynamic>;
}

/// Scripted create / commit / one quiet move / resign / flip on testnet.
Future<void> main() async {
  const rpc = 'https://rpc.testnet.fastnear.com';
  const contract = 'play.engkwentro.testnet';
  const aId = 'player1.engkwentro.testnet';
  const bId = 'player2.engkwentro.testnet';
  final aKey = cred(aId)['private_key'] as String;
  final bKey = cred(bId)['private_key'] as String;
  final mailbox = Mailbox('http://127.0.0.1:8787');

  final alice = NearClient(
    rpcUrl: rpc,
    accountId: aId,
    privateKey: aKey,
    contractId: contract,
  );
  final bob = NearClient(
    rpcUrl: rpc,
    accountId: bId,
    privateKey: bKey,
    contractId: contract,
  );
  await alice.ready();
  await bob.ready();

  final beforeA = await alice.balance();
  final beforeB = await bob.balance();
  print('before A=$beforeA B=$beforeB');

  final sa = NetSession(
    near: alice,
    mailbox: mailbox,
    sideA: true,
    opponent: bId,
  )..persist = false;
  final sb = NetSession(
    near: bob,
    mailbox: mailbox,
    sideA: false,
    opponent: aId,
  )..persist = false;

  await sa.create(clockMinutes: 15);
  print('match ${sa.matchId}');
  await sb.accept(sa.matchId!);
  print('accepted');
  await sa.commitDefault();
  print('alice committed');
  await sb.commitDefault();
  print('bob committed');
  await sa.confirmRoster();
  print('roster confirmed');
  var snap = await sa.refresh();
  print('after confirm ${snap.state} to_move=${snap.toMove}');

  // First legal forward step for whoever moves.
  /// First orthogonal step onto an empty square for [s].
  Future<void> oneQuiet(NetSession s) async {
    for (var from = 0; from < 72; from++) {
      if (!s.mine(s.occupancy[from])) continue;
      for (final d in [9, -9, 1, -1]) {
        final to = from + d;
        if (to < 0 || to > 71) continue;
        if (d.abs() == 1 && from ~/ 9 != to ~/ 9) continue;
        if (s.occupancy[to] != 0) continue;
        await s.move(from, to);
        return;
      }
    }
    throw StateError('no quiet move');
  }

  if (snap.toMove == 'A') {
    await oneQuiet(sa);
  } else {
    await sb.refresh();
    await oneQuiet(sb);
  }
  await sa.near.call('resign', {'match_id': sa.matchId});
  await sa.near.call('submit_setup', {
    'match_id': sa.matchId,
    'pieces': [
      for (var i = 0; i < 21; i++)
        [rankWire[sa.ranks[i].index], ..._square(true, i), sa.salts[i]],
    ],
  });
  await sb.near.call('submit_setup', {
    'match_id': sb.matchId ?? sa.matchId,
    'pieces': [
      for (var i = 0; i < 21; i++)
        [rankWire[sb.ranks[i].index], ..._square(false, i), sb.salts[i]],
    ],
  });
  await alice.call('settle', {'match_id': sa.matchId});
  await alice.call('claim_payout', {'match_id': sa.matchId});

  final afterA = await alice.balance();
  final afterB = await bob.balance();
  print('after  A=$afterA B=$afterB');
  print('spentA=${beforeA - afterA} spentB=${beforeB - afterB}');
  print(
    'spentA_NEAR=${_near(beforeA - afterA)} spentB_NEAR=${_near(beforeB - afterB)}',
  );
}

/// Default-army `[file, board_rank]` for roster index [i].
List<int> _square(bool sideA, int i) {
  final ranks = sideA ? [0, 1, 2] : [5, 6, 7];
  var n = 0;
  for (final boardRank in ranks) {
    final files = (sideA && boardRank == 2) || (!sideA && boardRank == 5)
        ? 3
        : 9;
    for (var file = 0; file < files; file++) {
      if (n == i) return [file, boardRank];
      n++;
    }
  }
  throw StateError('index');
}

/// Formats yoctoNEAR as a decimal string.
String _near(BigInt yocto) {
  final s = yocto.toString().padLeft(25, '0');
  return '${s.substring(0, s.length - 24)}.${s.substring(s.length - 24)}';
}
