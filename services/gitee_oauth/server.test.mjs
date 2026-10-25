import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import test from 'node:test';
import { createOAuthHandler } from './server.mjs';

const base = 'https://oauth.example.com/gitee';
const grantType = 'urn:ietf:params:oauth:grant-type:device_code';

function setup(options = {}) {
  let clock = Date.now();
  const requests = [];
  const handler = createOAuthHandler({
    clientId: 'client', clientSecret: 'server-secret', publicUrl: base,
    now: () => clock,
    fetch: async (url, options) => {
      requests.push({ url, ...options });
      return Response.json({ access_token: 'access', refresh_token: 'refresh', expires_in: 86400, scope: 'gists user_info' });
    },
    ...options,
  });
  async function request(path, { method = 'GET', body, headers = {}, address = '127.0.0.1' } = {}) {
    const req = Readable.from(body === undefined ? [] : [typeof body === 'string' ? body : JSON.stringify(body)]);
    req.url = path;
    req.method = method;
    req.headers = headers;
    req.socket = { remoteAddress: address };
    const res = {
      headers: {}, status: 200, headersSent: false,
      setHeader(key, value) { this.headers[key.toLowerCase()] = value; },
      writeHead(status, headers) {
        this.status = status;
        this.headersSent = true;
        for (const [key, value] of Object.entries(headers)) this.setHeader(key, value);
      },
      end(body) { this.body = body ?? ''; },
    };
    await handler(req, res);
    return res;
  }
  return { request, requests, advance: (ms) => { clock += ms; } };
}

async function start(server, options) {
  const response = await server.request('/gitee/device/code', { method: 'POST', ...options });
  assert.equal(response.status, 200);
  assert.equal(response.headers['cache-control'], 'no-store');
  return JSON.parse(response.body);
}

async function poll(server, code) {
  const response = await server.request('/gitee/token', { method: 'POST', body: { device_code: code, grant_type: grantType } });
  return JSON.parse(response.body);
}

test('browser authorization keeps device secret out of the browser and delivers a token once', async () => {
  const server = setup();
  const device = await start(server);
  assert.equal(device.verification_uri.includes(device.device_code), false);
  assert.equal(device.device_code.length, 43);
  const state = new URL(device.verification_uri).searchParams.get('state');
  assert.notEqual(state, device.device_code);
  const redirect = await server.request(new URL(device.verification_uri).pathname + new URL(device.verification_uri).search);
  const target = new URL(redirect.headers.location);
  assert.equal(target.origin, 'https://gitee.com');
  assert.equal(target.searchParams.get('scope'), 'gists user_info');
  assert.equal(target.searchParams.get('redirect_uri'), `${base}/callback`);
  assert.equal(target.searchParams.get('state'), state);
  assert.equal(redirect.body.includes('server-secret'), false);
  assert.deepEqual(await poll(server, device.device_code), { error: 'authorization_pending' });
  const callback = await server.request(`/gitee/callback?state=${state}&code=authorization-code`);
  assert.match(callback.body, /Authorized/);
  assert.equal(callback.body.includes('access_token'), false);
  assert.equal(server.requests.length, 1);
  assert.equal(server.requests[0].url, 'https://gitee.com/oauth/token');
  assert.equal(server.requests[0].body.get('client_secret'), 'server-secret');
  assert.equal(server.requests[0].body.get('code'), 'authorization-code');
  assert.equal(server.requests[0].redirect, 'error');
  assert.deepEqual(await poll(server, state), { error: 'expired_token' });
  assert.deepEqual(await poll(server, device.device_code), { access_token: 'access', refresh_token: 'refresh', expires_in: 86400, scope: 'gists user_info', token_type: 'bearer' });
  assert.deepEqual(await poll(server, device.device_code), { error: 'expired_token' });
  await server.request(`/gitee/callback?state=${state}&code=replay`);
  assert.equal(server.requests.length, 1);
});

test('unknown state and expired sessions never exchange an authorization code', async () => {
  const server = setup();
  await server.request('/gitee/callback?state=forged&code=attack');
  const device = await start(server);
  const state = new URL(device.verification_uri).searchParams.get('state');
  server.advance(600001);
  await server.request(`/gitee/callback?state=${state}&code=expired`);
  assert.equal(server.requests.length, 0);
  assert.deepEqual(await poll(server, device.device_code), { error: 'expired_token' });
});

test('denial belongs to the initiating device and cannot be replayed', async () => {
  const server = setup();
  const denied = await start(server);
  const other = await start(server);
  const state = new URL(denied.verification_uri).searchParams.get('state');
  await server.request(`/gitee/callback?state=${state}&error=access_denied`);
  assert.deepEqual(await poll(server, other.device_code), { error: 'authorization_pending' });
  assert.deepEqual(await poll(server, denied.device_code), { error: 'access_denied' });
  await server.request(`/gitee/callback?state=${state}&code=replay`);
  assert.equal(server.requests.length, 0);
});

test('missing scopes and token endpoint failures do not release tokens', async () => {
  for (const response of [Response.json({ access_token: 'secret', scope: 'user_info' }), new Response('failed', { status: 502 })]) {
    const server = setup({ fetch: async () => response });
    const device = await start(server);
    const state = new URL(device.verification_uri).searchParams.get('state');
    const callback = await server.request(`/gitee/callback?state=${state}&code=test`);
    assert.match(callback.body, /Authorization failed/);
    assert.deepEqual(await poll(server, device.device_code), { error: 'exchange_failed' });
  }
});

test('rate limits, poll interval and request limits bound unauthenticated work', async () => {
  const server = setup();
  const device = await start(server);
  assert.deepEqual(await poll(server, device.device_code), { error: 'authorization_pending' });
  assert.deepEqual(await poll(server, device.device_code), { error: 'slow_down' });
  const malformed = await server.request('/gitee/token', { method: 'POST', body: '{' });
  assert.equal(malformed.status, 400);
  const oversized = await server.request('/gitee/token', { method: 'POST', body: 'a'.repeat(4097) });
  assert.equal(oversized.status, 400);
  for (let i = 1; i < 60; i++) await start(server);
  const limited = await server.request('/gitee/device/code', { method: 'POST' });
  assert.equal(limited.status, 429);
  server.advance(600001);
  await start(server);
});

test('refresh uses the server secret and returns only credential fields', async () => {
  const server = setup();
  const response = await server.request('/gitee/refresh', { method: 'POST', body: { refresh_token: 'old-refresh', client_secret: 'untrusted' } });
  assert.equal(JSON.parse(response.body).access_token, 'access');
  assert.equal(server.requests[0].body.get('refresh_token'), 'old-refresh');
  assert.equal(server.requests[0].body.get('client_secret'), 'server-secret');
  assert.equal(response.body.includes('server-secret'), false);
  const rejected = await setup({ fetch: async () => new Response('', { status: 401 }) }).request('/gitee/refresh', { method: 'POST', body: { refresh_token: 'bad' } });
  assert.equal(rejected.status, 401);
});

test('only an explicitly trusted reverse proxy can supply a rate limit address', async () => {
  for (const trustProxy of [false, true]) {
    const server = setup({ trustProxy });
    for (let i = 0; i < 60; i++) await start(server, { headers: { 'x-forwarded-for': 'first' } });
    const response = await server.request('/gitee/device/code', { method: 'POST', headers: { 'x-forwarded-for': 'second' } });
    assert.equal(response.status, trustProxy ? 200 : 429);
  }
});

test('configuration refuses insecure public URLs', () => {
  for (const publicUrl of ['http://oauth.example.com', 'https://user@oauth.example.com', 'https://oauth.example.com?token=test']) {
    assert.throws(() => createOAuthHandler({ publicUrl, clientId: 'client', clientSecret: 'secret' }));
  }
});

test('a service at the origin root produces URLs without a double slash', async () => {
  const server = setup({ publicUrl: 'https://oauth.example.com/' });
  const response = await server.request('/device/code', { method: 'POST' });
  assert.equal(response.status, 200);
  const uri = new URL(JSON.parse(response.body).verification_uri);
  assert.equal(uri.pathname, '/authorize');
  const redirect = await server.request(`/authorize${uri.search}`);
  assert.equal(new URL(redirect.headers.location).searchParams.get('redirect_uri'), 'https://oauth.example.com/callback');
});
