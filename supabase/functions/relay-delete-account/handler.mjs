const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
  'Cache-Control': 'no-store',
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const response = (status, body) => new Response(JSON.stringify(body), {status, headers});

// Auth verifies the token before any decoded claim is used. This decoder only
// extracts the session id for an additional live-session database check.
function sessionId(token, userId) {
  try {
    const part = token.split('.')[1];
    const claims = JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/')));
    if (claims.sub !== userId || claims.role !== 'authenticated' ||
        typeof claims.exp !== 'number' || claims.exp * 1000 <= Date.now() ||
        !uuid.test(claims.session_id ?? '')) return null;
    return claims.session_id;
  } catch {
    return null;
  }
}

export function createHandler(deps) {
  return async function handle(req) {
    if (req.method === 'OPTIONS') return new Response(null, {status: 204, headers});
    if (req.method !== 'POST') return response(405, {error: 'Use POST to delete your account.'});
    const auth = req.headers.get('Authorization');
    if (!auth?.match(/^Bearer\s+\S+$/i)) {
      return response(401, {error: 'Sign in again before deleting your account.'});
    }
    const token = auth.replace(/^Bearer\s+/i, '');
    try {
      const raw = await req.text();
      if (raw.length > 1024) return response(413, {error: 'Request is too large.'});
      let body;
      try { body = JSON.parse(raw); } catch {
        return response(400, {error: 'Confirm account deletion before continuing.'});
      }
      if (!body || body.confirmation !== 'DELETE' || Object.keys(body).length !== 1) {
        return response(400, {error: 'Confirm account deletion before continuing.'});
      }
      const user = await deps.getUser(token);
      if (!user || !uuid.test(user.id ?? '')) {
        return response(401, {error: 'Sign in again before deleting your account.'});
      }
      const session = sessionId(token, user.id);
      if (!session || !await deps.isSessionActive(user.id, session)) {
        return response(401, {error: 'Sign in again before deleting your account.'});
      }
      // Revoke every session before deletion. The trigger handles household
      // cleanup atomically without deleting other caregivers' accounts/history.
      await deps.signOutEverywhere(token);
      await deps.deleteUser(user.id);
      return response(200, {deleted: true});
    } catch {
      // Never log tokens, account details, request payloads or database errors.
      return response(500, {error: 'Could not complete account deletion. Sign in again and retry, or contact support.'});
    }
  };
}
