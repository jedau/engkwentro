import 'join_key.dart';
import 'mailbox.dart';
import 'near.dart';
import 'net_page.dart';
import 'net_play.dart';

/// Boots a [NetSession] from [config], loading mailbox keys when needed.
///
/// When [openChallenge] is true, `create_match` gets no named opponent.
Future<NetSession> bootSession(
  NetConfig config, {
  bool openChallenge = false,
}) async {
  final cfg = config.ready ? config : await config.withMailboxCreds();
  final session = NetSession(
    near: NearClient(
      rpcUrl: cfg.rpc,
      accountId: cfg.account,
      privateKey: cfg.key,
      contractId: cfg.contract,
    ),
    mailbox: Mailbox(cfg.mailbox),
    sideA: cfg.roleA,
    opponent: openChallenge ? '' : cfg.opponent,
  )..log = 'Signed in as ${cfg.account}.';
  await session.near.ready();
  return session;
}

/// Open challenge: create with no named opponent, then wait on the key.
Future<NetSession> createOpenMatch(
  NetConfig base, {
  int clockMinutes = 15,
  String stakeYocto = '0',
}) async {
  final session = await bootSession(
    base.copyWith(roleA: true),
    openChallenge: true,
  );
  await session.create(clockMinutes: clockMinutes, stakeYocto: stakeYocto);
  final key = session.joinKey != null
      ? formatJoinKey(session.joinKey!)
      : 'the match key';
  session.log = 'Share $key. Waiting for opponent.';
  return session;
}

/// Join by [rawKey]. Throws if the key is bad or accept fails.
Future<NetSession> joinByKey(NetConfig base, String rawKey) async {
  return resumeMatch(base, rawKey);
}

/// Rejoin (or first-join) by 12-char key or numeric match id.
///
/// Creator and opponent both attach. Accepts on-chain only when still open.
Future<NetSession> resumeMatch(NetConfig base, String raw) async {
  final session = await bootSession(base);
  await session.resume(raw);
  return session;
}
