import assert from 'node:assert/strict';
import test from 'node:test';
import {createHandler, hashedRateBucket} from './handler.mjs';

const key = 'sb_publishable_test';
const feedback = {
  action: 'feedback', category: 'idea', message: 'Please make the schedule easier to read.',
  appVersion: '1.17.0+22', platform: 'android',
};
const diagnostic = {
  action: 'diagnostic', eventType: 'flutter_error', code: 'FlutterError',
  appVersion: '1.17.0+22', platform: 'web', fingerprint: '0a12bc34',
  frames: ['package:relay/main.dart:123:45'],
};

function fixture(overrides = {}) {
  const calls = [];
  const deps = {
    publishableKey: key,
    now: () => new Date('2026-11-19T12:00:00.000Z'),
    getUser: async token => {
      calls.push(['auth', token]);
      return token === 'valid-user' ? {
        id: '11111111-1111-4111-8111-111111111111',
        email: 'LUHLOSTUDIOS@gmail.com', email_confirmed_at: '2026-01-01T00:00:00Z',
      } : null;
    },
    isAdmin: async email => { calls.push(['admin', email]); return email === 'luhlostudios@gmail.com'; },
    rateBucket: async () => 'a'.repeat(64),
    takeRate: async (bucket, kind) => { calls.push(['rate', bucket, kind]); return true; },
    saveFeedback: async record => { calls.push(['feedback', record]); },
    saveDiagnostic: async record => { calls.push(['diagnostic', record]); },
    dashboard: async since => { calls.push(['dashboard', since]); return {feedback: [], diagnostics: []}; },
    ...overrides,
  };
  return {calls, handle: createHandler(deps)};
}

function request(body, {method = 'POST', origin, headers = {}} = {}) {
  return new Request('https://project.supabase.co/functions/v1/relay-support', {
    method,
    headers: {apikey: key, 'Content-Type': 'application/json', ...(origin ? {Origin: origin} : {}), ...headers},
    ...(method === 'GET' || method === 'OPTIONS' ? {} : {body: typeof body === 'string' ? body : JSON.stringify(body)}),
  });
}

test('guest feedback accepts only the intended fields and normalizes storage', async () => {
  const {handle, calls} = fixture();
  const result = await handle(request({...feedback, message: `  ${feedback.message}  `, replyEmail: 'reply@example.com'}));
  assert.equal(result.status, 202);
  assert.deepEqual(await result.json(), {ok: true});
  assert.deepEqual(calls.map(call => call[0]), ['rate', 'feedback']);
  assert.deepEqual(calls[1][1], {
    category: 'idea', message: feedback.message, reply_email: 'reply@example.com',
    app_version: '1.17.0+22', platform: 'android',
  });
});

test('guest diagnostics store app-source locations without user identity or error messages', async () => {
  const {handle, calls} = fixture();
  const result = await handle(request(diagnostic));
  assert.equal(result.status, 202);
  const saved = calls.find(call => call[0] === 'diagnostic')[1];
  assert.deepEqual(Object.keys(saved).sort(), ['event_type', 'code', 'operation', 'duration_ms', 'app_version', 'platform', 'fingerprint', 'frames'].sort());
  assert.deepEqual(saved.frames, ['package:relay/main.dart:123:45']);
  assert.equal(saved.duration_ms, null);
  assert.equal(calls.some(call => call[0] === 'auth'), false);
});

test('slow operation and frame reports enforce their codes, timing and operation', async () => {
  for (const extra of [
    {eventType: 'slow_operation', code: 'SlowOperation', operation: 'load_records', durationMs: 3500},
    {eventType: 'slow_frame', code: 'SlowFrame', operation: 'render', durationMs: 80},
  ]) {
    const {handle} = fixture();
    assert.equal((await handle(request({...diagnostic, ...extra}))).status, 202);
  }
  for (const extra of [
    {eventType: 'slow_operation', code: 'SlowOperation'},
    {eventType: 'slow_operation', code: 'StateError', operation: 'load_records', durationMs: 1},
    {eventType: 'slow_frame', code: 'SlowFrame', operation: 'load_records', durationMs: 1},
  ]) {
    const {handle, calls} = fixture();
    assert.equal((await handle(request({...diagnostic, ...extra}))).status, 400);
    assert.equal(calls.length, 0);
  }
});

test('feedback rejects private metadata, invalid categories and excessive text', async () => {
  for (const extra of [
    {userId: 'other-user'}, {household: 'private'}, {category: 'other'},
    {message: 'short'}, {message: 'x'.repeat(2001)}, {message: 'valid message\u0000bad'},
    {replyEmail: 'bad'}, {replyEmail: 'parent@example.com\nsecret'}, {replyEmail: 42},
    {appVersion: 'email@example.com'}, {platform: 'my-phone-name'},
  ]) {
    const {handle, calls} = fixture();
    const result = await handle(request({...feedback, ...extra}));
    assert.equal(result.status, 400, JSON.stringify(extra));
    assert.equal(calls.length, 0);
  }
});

test('diagnostics reject raw messages, URLs, identity and unsupported frame content', async () => {
  for (const extra of [
    {message: 'child name'}, {email: 'parent@example.com'}, {userId: 'other-user'},
    {deviceId: 'tracking-id'}, {code: 'child name'}, {eventType: 'screen_view'},
    {operation: 'Child name'}, {durationMs: -1}, {durationMs: 1.2}, {durationMs: 86_400_001},
    {fingerprint: 'parent@example.com'}, {fingerprint: 'abc'},
    {frames: ['https://relay.luhlo.com/?token=secret']},
    {frames: ['#0 childName (package:relay/main.dart:1:1)']},
    {frames: ['package:relay/../secret.dart:1:1']},
    {frames: ['file:///private/path.dart:1:1']},
    {frames: Array(11).fill('package:relay/main.dart:1:1')},
    {frames: null},
  ]) {
    const {handle, calls} = fixture();
    assert.equal((await handle(request({...diagnostic, ...extra}))).status, 400, JSON.stringify(extra));
    assert.equal(calls.length, 0);
  }
});

test('web reports can omit unreadable app frames', async () => {
  const {handle} = fixture();
  assert.equal((await handle(request({...diagnostic, frames: []}))).status, 202);
});

test('CORS permits the production site and local development origins only', async () => {
  for (const origin of ['https://relay.luhlo.com', 'http://localhost:8765', 'http://127.0.0.1:8765', 'https://localhost']) {
    const {handle} = fixture();
    const result = await handle(request(feedback, {origin}));
    assert.equal(result.status, 202);
    assert.equal(result.headers.get('Access-Control-Allow-Origin'), origin);
    assert.equal(result.headers.get('Cache-Control'), 'no-store');
  }
  for (const origin of ['https://example.com', 'https://relay.luhlo.com.evil.test', 'http://localhost.evil.test', 'null', 'https://relay.luhlo.com/path']) {
    const {handle, calls} = fixture();
    const result = await handle(request(feedback, {origin}));
    assert.equal(result.status, 403);
    assert.equal(result.headers.get('Access-Control-Allow-Origin'), null);
    assert.equal(calls.length, 0);
  }
});

test('preflight accepts allowed origins without an API key or database call', async () => {
  const {handle, calls} = fixture();
  const result = await handle(new Request('https://project.supabase.co/functions/v1/relay-support', {
    method: 'OPTIONS', headers: {Origin: 'https://relay.luhlo.com'},
  }));
  assert.equal(result.status, 204);
  assert.equal(calls.length, 0);
});

test('unsupported methods, missing API keys and non-JSON are rejected before storage', async () => {
  for (const options of [
    {method: 'GET', expected: 405},
    {headers: {apikey: 'wrong'}, expected: 401},
    {headers: {'Content-Type': 'text/plain'}, expected: 415},
  ]) {
    const {handle, calls} = fixture();
    assert.equal((await handle(request(feedback, options))).status, options.expected);
    assert.equal(calls.length, 0);
  }
});

test('malformed objects and unknown actions fail without database activity', async () => {
  for (const body of ['invalid', 'null', '[]', '42', '{}', '{"action":"dashboard","userId":"other"}', '{"action":"capabilities","email":"owner@example.com"}']) {
    const {handle, calls} = fixture();
    assert.equal((await handle(request(body))).status, 400);
    assert.equal(calls.length, 0);
  }
});

test('request size is bounded by actual UTF-8 bytes as well as declared length', async () => {
  for (const req of [
    request('x'.repeat(12 * 1024 + 1)),
    request({...feedback, message: '🍼'.repeat(4000)}),
    request(feedback, {headers: {'Content-Length': '12289'}}),
  ]) {
    const {handle, calls} = fixture();
    assert.equal((await handle(req)).status, 413);
    assert.equal(calls.length, 0);
  }
});

test('missing or invalid authentication cannot read admin reports', async () => {
  for (const auth of [undefined, 'Bearer invalid-user', 'Basic token']) {
    for (const action of ['capabilities', 'dashboard']) {
      const {handle, calls} = fixture();
      const result = await handle(request({action}, {headers: auth ? {Authorization: auth} : {}}));
      assert.equal(result.status, action === 'capabilities' ? 200 : 403);
      if (action === 'capabilities') assert.deepEqual(await result.json(), {canViewReports: false});
      assert.equal(calls.some(call => call[0] === 'dashboard'), false);
      assert.equal(calls.some(call => call[0] === 'admin'), false);
    }
  }
});

test('verified admin email is lowercased after authoritative Auth validation', async () => {
  const {handle, calls} = fixture();
  const result = await handle(request({action: 'capabilities'}, {headers: {Authorization: 'Bearer valid-user'}}));
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), {canViewReports: true});
  assert.deepEqual(calls, [['auth', 'valid-user'], ['admin', 'luhlostudios@gmail.com']]);
});

test('unconfirmed, anonymous and nonadmin users cannot become admin through user metadata', async () => {
  for (const user of [
    {email: 'luhlostudios@gmail.com', email_confirmed_at: null},
    {email: 'luhlostudios@gmail.com', email_confirmed_at: 'confirmed', is_anonymous: true},
    {email: 'regular@example.com', email_confirmed_at: 'confirmed', user_metadata: {role: 'admin', email: 'luhlostudios@gmail.com'}},
  ]) {
    const {handle, calls} = fixture({getUser: async () => user});
    const result = await handle(request({action: 'dashboard'}, {headers: {Authorization: 'Bearer valid-user'}}));
    assert.equal(result.status, 403);
    assert.equal(calls.some(call => call[0] === 'dashboard'), false);
  }
});

test('admin dashboard requests exactly the trailing 30-day window', async () => {
  const {handle, calls} = fixture();
  const result = await handle(request({action: 'dashboard'}, {headers: {Authorization: 'Bearer valid-user'}}));
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), {feedback: [], diagnostics: [], since: '2026-10-20T12:00:00.000Z'});
  assert.deepEqual(calls.at(-1), ['dashboard', '2026-10-20T12:00:00.000Z']);
  assert.equal(calls.some(call => call[0] === 'rate'), false);
});

test('rate limit denial prevents writes and signals retry', async () => {
  const {handle, calls} = fixture({takeRate: async () => false});
  const result = await handle(request(feedback));
  assert.equal(result.status, 429);
  assert.equal(result.headers.get('Retry-After'), '3600');
  assert.equal(calls.some(call => call[0] === 'feedback'), false);
});

test('database/auth failures fail closed without leaking error details', async () => {
  for (const [override, body, auth] of [
    [{takeRate: async () => { throw new Error('private database details'); }}, feedback],
    [{saveDiagnostic: async () => { throw new Error('private record'); }}, diagnostic],
    [{isAdmin: async () => { throw new Error('private email'); }}, {action: 'dashboard'}, 'valid-user'],
    [{getUser: async () => { throw new Error('private token'); }}, {action: 'capabilities'}, 'valid-user'],
  ]) {
    const {handle} = fixture(override);
    const result = await handle(request(body, {headers: auth ? {Authorization: `Bearer ${auth}`} : {}}));
    assert.equal(result.status, 503);
    assert.equal((await result.text()).includes('private'), false);
  }
});

test('HMAC rate buckets contain no raw IP and change with the server secret', async () => {
  const req = request(feedback, {headers: {'cf-connecting-ip': '192.0.2.10'}});
  const first = await hashedRateBucket(req, 'test-only-secret');
  assert.match(first, /^[a-f0-9]{64}$/);
  assert.equal(first.includes('192.0.2.10'), false);
  assert.equal(await hashedRateBucket(req, 'test-only-secret'), first);
  assert.notEqual(await hashedRateBucket(req, 'different-test-secret'), first);
});
