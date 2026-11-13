#!/usr/bin/env node
// Local OT mailbox for two emulators. No secrets. Keyed blobs only.
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

const store = new Map();

const server = http.createServer((req, res) => {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS');
  res.setHeader('access-control-allow-headers', 'content-type');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/dev/cred' && req.method === 'GET') {
    const role = url.searchParams.get('role') === 'B' ? 'B' : 'A';
    const account = role === 'A' ? 'player1.engkwentro.testnet' : 'player2.engkwentro.testnet';
    const opponent = role === 'A' ? 'player2.engkwentro.testnet' : 'player1.engkwentro.testnet';
    const file = path.join(os.homedir(), '.near-credentials', 'testnet', `${account}.json`);
    const cred = JSON.parse(fs.readFileSync(file, 'utf8'));
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      role,
      account,
      opponent,
      private_key: cred.private_key,
    }));
    return;
  }
  if (url.pathname === '/health' || url.pathname === '/') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, service: 'engkwentro-mailbox', keys: store.size }));
    return;
  }
  if (url.pathname === '/mailbox' && req.method === 'POST') {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
    });
    req.on('end', () => {
      const body = JSON.parse(raw || '{}');
      const key = `${body.match_id}:${body.key ?? 'default'}`;
      store.set(key, body.blob ?? '');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, key }));
    });
    return;
  }
  if (url.pathname === '/mailbox' && req.method === 'GET') {
    const matchId = url.searchParams.get('match_id') ?? '';
    const slot = url.searchParams.get('key') ?? 'default';
    const blob = store.get(`${matchId}:${slot}`) ?? null;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ match_id: matchId, key: slot, blob }));
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

const port = Number(process.env.MAILBOX_PORT || 8787);
server.listen(port, '0.0.0.0', () => {
  console.log(`mailbox on http://0.0.0.0:${port}`);
});
