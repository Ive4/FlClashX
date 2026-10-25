import { randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';

const lifetime = 10 * 60 * 1000;
const grantType = 'urn:ietf:params:oauth:grant-type:device_code';
const scopes = ['gists', 'user_info'];
const nonce = () => randomBytes(32).toString('base64url');

export function createOAuthHandler({
  clientId,
  clientSecret,
  publicUrl,
  fetch = globalThis.fetch,
  now = Date.now,
  trustProxy = false,
}) {
  const base = new URL(publicUrl);
  if (!clientId || !clientSecret || base.protocol !== 'https:' ||
      base.username || base.password || base.search || base.hash) {
    throw new Error('Set GITEE_CLIENT_ID, GITEE_CLIENT_SECRET and an HTTPS PUBLIC_URL');
  }
  const prefix = base.pathname.replace(/\/+$/, '');
  const endpoint = (path) => `${base.origin}${prefix}${path}`;
  const sessions = new Map();
  const states = new Map();
  const starts = new Map();
  let exchanges = 0;

  function admit(req, operation) {
    const forwarded = req.headers['x-forwarded-for'];
    const address = trustProxy && typeof forwarded === 'string'
      ? forwarded.split(',').at(-1).trim() : req.socket.remoteAddress;
    const key = `${operation}:${address}`;
    const entry = starts.get(key) ?? { count: 0, expires: now() + lifetime };
    if (starts.size >= 1000 || entry.count >= 60) return false;
    entry.count++;
    starts.set(key, entry);
    return true;
  }

  function remove(deviceCode, session) {
    clearTimeout(session.timer);
    sessions.delete(deviceCode);
    states.delete(session.state);
  }

  function prune() {
    for (const [code, session] of sessions) {
      if (session.expires <= now()) remove(code, session);
    }
    for (const [key, start] of starts) {
      if (start.expires <= now()) starts.delete(key);
    }
  }

  function json(res, body, status = 200) {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  }

  function page(res, success) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html><html lang="zh-CN"><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>FlClash · Gitee</title><body><h1>${success ? '授权成功 / Authorized' : '授权未完成 / Authorization failed'}</h1>
      <p>${success ? '请返回 FlClash，可以关闭此页面。 / Return to FlClash. You can close this page.' : '请返回 FlClash 重试。 / Return to FlClash and retry.'}</p></body></html>`);
  }

  async function readBody(req) {
    let body = '';
    for await (const chunk of req) {
      body += chunk;
      if (Buffer.byteLength(body) > 4096) throw new Error('body_too_large');
    }
    return JSON.parse(body || '{}');
  }

  async function exchange(parameters) {
    if (exchanges >= 20) throw new Error('busy');
    exchanges++;
    try {
      return await exchangeToken(parameters);
    } finally {
      exchanges--;
    }
  }

  async function exchangeToken(parameters) {
    const response = await fetch('https://gitee.com/oauth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: new URLSearchParams({
        ...parameters,
        client_id: clientId,
        client_secret: clientSecret,
      }),
      redirect: 'error',
      signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) throw new Error('exchange_failed');
    const token = await response.json();
    const granted = typeof token.scope === 'string' ? token.scope.split(/[ ,]+/) : [];
    if (typeof token.access_token !== 'string' || !token.access_token ||
        !scopes.every((scope) => granted.includes(scope))) {
      throw new Error('insufficient_scope');
    }
    return {
      access_token: token.access_token,
      scope: token.scope,
      token_type: 'bearer',
      ...(typeof token.refresh_token === 'string' && { refresh_token: token.refresh_token }),
      ...(Number.isFinite(token.expires_in) && { expires_in: token.expires_in }),
    };
  }

  return async function handle(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    res.setHeader('X-Content-Type-Options', 'nosniff');
    prune();
    try {
      const url = new URL(req.url, base.origin);
      if (req.method === 'POST' && url.pathname === `${prefix}/device/code`) {
        if (sessions.size >= 1000 || !admit(req, 'start')) {
          return json(res, { error: 'rate_limited' }, 429);
        }
        const deviceCode = nonce();
        const state = nonce();
        const session = { state, expires: now() + lifetime, status: 'pending', nextPoll: 0 };
        session.timer = setTimeout(() => remove(deviceCode, session), lifetime);
        session.timer.unref();
        sessions.set(deviceCode, session);
        states.set(state, deviceCode);
        return json(res, {
          device_code: deviceCode,
          verification_uri: `${endpoint('/authorize')}?state=${state}`,
          expires_in: lifetime / 1000,
          interval: 5,
        });
      }
      if (req.method === 'GET' && url.pathname === `${prefix}/authorize`) {
        const state = url.searchParams.get('state');
        const session = sessions.get(states.get(state));
        if (!session || session.status !== 'pending') return page(res, false);
        const target = new URL('https://gitee.com/oauth/authorize');
        target.search = new URLSearchParams({
          client_id: clientId,
          redirect_uri: endpoint('/callback'),
          response_type: 'code',
          scope: scopes.join(' '),
          state,
        }).toString();
        res.writeHead(302, { Location: target.toString() });
        return res.end();
      }
      if (req.method === 'GET' && url.pathname === `${prefix}/callback`) {
        const state = url.searchParams.get('state');
        const deviceCode = states.get(state);
        const session = sessions.get(deviceCode);
        if (!session || session.status !== 'pending') return page(res, false);
        states.delete(state);
        if (url.searchParams.has('error')) {
          session.status = 'access_denied';
          return page(res, false);
        }
        const code = url.searchParams.get('code');
        if (!code || code.length > 1024) {
          session.status = 'access_denied';
          return page(res, false);
        }
        session.status = 'exchanging';
        try {
          const token = await exchange({ grant_type: 'authorization_code', code, redirect_uri: endpoint('/callback') });
          if (session.expires <= now() || !sessions.has(deviceCode)) return page(res, false);
          session.token = token;
          session.status = 'authorized';
          return page(res, true);
        } catch {
          session.status = 'exchange_failed';
          return page(res, false);
        }
      }
      if (req.method === 'POST' && url.pathname === `${prefix}/token`) {
        const body = await readBody(req);
        if (body.grant_type !== grantType) return json(res, { error: 'unsupported_grant_type' }, 400);
        const session = sessions.get(body.device_code);
        if (!session) return json(res, { error: 'expired_token' });
        if (session.status === 'authorized') {
          remove(body.device_code, session);
          return json(res, session.token);
        }
        if (session.status === 'access_denied' || session.status === 'exchange_failed') {
          remove(body.device_code, session);
          return json(res, { error: session.status });
        }
        if (session.nextPoll > now()) return json(res, { error: 'slow_down' });
        session.nextPoll = now() + 5000;
        return json(res, { error: 'authorization_pending' });
      }
      if (req.method === 'POST' && url.pathname === `${prefix}/refresh`) {
        if (!admit(req, 'refresh')) return json(res, { error: 'rate_limited' }, 429);
        const body = await readBody(req);
        if (typeof body.refresh_token !== 'string' || !body.refresh_token || body.refresh_token.length > 2048) {
          return json(res, { error: 'invalid_grant' }, 400);
        }
        try {
          return json(res, await exchange({ grant_type: 'refresh_token', refresh_token: body.refresh_token }));
        } catch {
          return json(res, { error: 'invalid_grant' }, 401);
        }
      }
      return json(res, { error: 'not_found' }, 404);
    } catch {
      if (!res.headersSent) json(res, { error: 'invalid_request' }, 400);
      else res.end();
    }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = createServer(createOAuthHandler({
    clientId: process.env.GITEE_CLIENT_ID,
    clientSecret: process.env.GITEE_CLIENT_SECRET,
    publicUrl: process.env.PUBLIC_URL,
    trustProxy: process.env.TRUST_PROXY === 'true',
  }));
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  server.listen(Number(process.env.PORT ?? 8787), process.env.HOST ?? '127.0.0.1');
}
