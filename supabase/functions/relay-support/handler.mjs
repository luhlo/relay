const MAX_BODY_BYTES = 12 * 1024;
const encoder = new TextEncoder();
const categories = new Set(['problem', 'idea', 'question']);
const eventTypes = new Set(['flutter_error', 'unhandled_error', 'slow_operation', 'slow_frame']);
const codes = new Set([
  'FlutterError', 'StateError', 'TypeError', 'RangeError', 'ArgumentError',
  'AssertionError', 'FormatException', 'TimeoutException', 'PlatformException',
  'MissingPluginException', 'PostgrestException', 'AuthException',
  'SocketException', 'Exception', 'UnknownError', 'SlowOperation', 'SlowFrame',
]);
const operations = new Set(['load_records', 'save_records', 'launch', 'render']);
const platforms = new Set(['web', 'android', 'ios', 'linux', 'macos', 'windows', 'fuchsia', 'unknown']);
const safeFrame = /^package:relay\/[a-zA-Z0-9_/.-]+\.dart:\d{1,6}:\d{1,5}$/;
const version = /^\d{1,3}\.\d{1,3}\.\d{1,3}(?:\+\d{1,9})?$/;
const email = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

function allowedOrigin(origin) {
  if (origin === null) return true; // Native clients do not send Origin.
  if (origin === 'https://relay.luhlo.com') return true;
  try {
    const url = new URL(origin);
    return url.origin === origin && ['http:', 'https:'].includes(url.protocol) &&
      ['localhost', '127.0.0.1'].includes(url.hostname);
  } catch {
    return false;
  }
}

function response(req, status, body, extraHeaders = {}) {
  const origin = req.headers.get('Origin');
  const headers = {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Origin',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    ...extraHeaders,
  };
  if (origin !== null && allowedOrigin(origin)) headers['Access-Control-Allow-Origin'] = origin;
  return new Response(body === null ? null : JSON.stringify(body), {status, headers});
}

const onlyKeys = (body, keys) => Object.keys(body).every(key => keys.includes(key));
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const validContext = body => typeof body.appVersion === 'string' && version.test(body.appVersion) &&
  platforms.has(body.platform);

function feedbackRecord(body) {
  if (!onlyKeys(body, ['action', 'category', 'message', 'replyEmail', 'appVersion', 'platform']) ||
      !categories.has(body.category) || !validContext(body) || typeof body.message !== 'string') return null;
  const message = body.message.trim();
  const replyEmail = body.replyEmail == null || body.replyEmail === '' ? null : body.replyEmail;
  if (message.length < 10 || message.length > 2000 || /\u0000/.test(message) ||
      (replyEmail !== null && (typeof replyEmail !== 'string' || replyEmail.length > 254 ||
        !email.test(replyEmail)))) return null;
  return {
    category: body.category, message, reply_email: replyEmail,
    app_version: body.appVersion, platform: body.platform,
  };
}

function diagnosticRecord(body) {
  if (!onlyKeys(body, ['action', 'eventType', 'code', 'operation', 'durationMs', 'appVersion', 'platform', 'fingerprint', 'frames']) ||
      !eventTypes.has(body.eventType) || !codes.has(body.code) || !validContext(body) ||
      (body.operation != null && !operations.has(body.operation)) ||
      (body.durationMs != null && (!Number.isInteger(body.durationMs) || body.durationMs < 0 || body.durationMs > 86_400_000)) ||
      typeof body.fingerprint !== 'string' || !/^[a-f0-9]{8,64}$/.test(body.fingerprint) ||
      !Array.isArray(body.frames) || body.frames.length > 10 ||
      !body.frames.every(frame => typeof frame === 'string' && frame.length <= 200 && safeFrame.test(frame) && !frame.includes('..')) ||
      (body.eventType === 'slow_operation' && (body.code !== 'SlowOperation' || body.operation == null || body.durationMs == null)) ||
      (body.eventType === 'slow_frame' && (body.code !== 'SlowFrame' || body.operation !== 'render' || body.durationMs == null))) return null;
  return {
    event_type: body.eventType, code: body.code, operation: body.operation ?? null,
    duration_ms: body.durationMs ?? null, app_version: body.appVersion,
    platform: body.platform, fingerprint: body.fingerprint, frames: body.frames,
  };
}

async function boundedBody(req) {
  const declared = req.headers.get('Content-Length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_BODY_BYTES)) {
    return {status: 413};
  }
  if (!req.body) return {status: 400};
  const reader = req.body.getReader();
  let length = 0;
  const chunks = [];
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_BODY_BYTES) {
        await reader.cancel();
        return {status: 413};
      }
      chunks.push(value);
    }
    const raw = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { raw.set(chunk, offset); offset += chunk.byteLength; }
    const body = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(raw));
    return isObject(body) ? {body} : {status: 400};
  } catch {
    return {status: 400};
  } finally {
    reader.releaseLock();
  }
}

async function adminAccess(req, deps) {
  const auth = req.headers.get('Authorization');
  if (!auth?.match(/^Bearer\s+\S+$/i)) return false;
  const user = await deps.getUser(auth.replace(/^Bearer\s+/i, ''));
  if (!user || user.is_anonymous === true || !user.email_confirmed_at || typeof user.email !== 'string') return false;
  return await deps.isAdmin(user.email.toLowerCase());
}

/** Public collection accepts only predefined fields. Private reads always verify Auth server-side. */
export function createHandler(deps) {
  return async function handle(req) {
    if (!allowedOrigin(req.headers.get('Origin'))) return response(req, 403, {error: 'Origin is not allowed.'});
    if (req.method === 'OPTIONS') return response(req, 204, null);
    if (req.method !== 'POST') return response(req, 405, {error: 'Use POST.'});
    if (req.headers.get('apikey') !== deps.publishableKey) return response(req, 401, {error: 'App authorization is required.'});
    if (!/^application\/json(?:;|$)/i.test(req.headers.get('Content-Type') ?? '')) {
      return response(req, 415, {error: 'Use a JSON request.'});
    }
    const parsed = await boundedBody(req);
    if (!parsed.body) return response(req, parsed.status, {error: parsed.status === 413 ? 'Request is too large.' : 'Invalid request.'});
    const body = parsed.body;
    try {
      if (body.action === 'capabilities' && onlyKeys(body, ['action'])) {
        return response(req, 200, {canViewReports: await adminAccess(req, deps)});
      }
      if (body.action === 'dashboard' && onlyKeys(body, ['action'])) {
        if (!await adminAccess(req, deps)) return response(req, 403, {error: 'Report access is restricted.'});
        const since = new Date((deps.now?.() ?? new Date()).getTime() - 30 * 24 * 60 * 60 * 1000).toISOString();
        const data = await deps.dashboard(since);
        return response(req, 200, {feedback: data.feedback, diagnostics: data.diagnostics, since});
      }
      const record = body.action === 'feedback' ? feedbackRecord(body) :
        body.action === 'diagnostic' ? diagnosticRecord(body) : null;
      if (record === null) return response(req, 400, {error: 'Invalid report. Check the fields and try again.'});
      const bucket = await deps.rateBucket(req);
      if (!await deps.takeRate(bucket, body.action)) {
        return response(req, 429, {error: 'Too many reports. Please try again later.'}, {'Retry-After': '3600'});
      }
      if (body.action === 'feedback') await deps.saveFeedback(record);
      else await deps.saveDiagnostic(record);
      return response(req, 202, {ok: true});
    } catch {
      // Deliberately omit error details, raw messages, credentials, IPs and payloads.
      return response(req, 503, {error: 'Reports are temporarily unavailable. Please try again later.'});
    }
  };
}

/** Only an HMAC enters the short-lived limiter table. Raw addresses never enter report rows. */
export async function hashedRateBucket(req, secret) {
  const forwarded = req.headers.get('x-forwarded-for')?.split(',').map(value => value.trim()).filter(Boolean);
  const candidate = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? forwarded?.at(-1) ?? 'unknown';
  const address = /^[a-fA-F0-9:.]{1,64}$/.test(candidate) ? candidate.toLowerCase() : 'unknown';
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), {name: 'HMAC', hash: 'SHA-256'}, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(`relay-support-rate-v1:${address}`));
  return [...new Uint8Array(signature)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
