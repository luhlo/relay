import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { createHandler } from './handler.mjs';

const url = Deno.env.get('SUPABASE_URL');
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if (!url || !key) throw new Error('Account deletion backend is not configured.');

// The service key is provided by Supabase Edge secrets, never by the app.
const admin = createClient(url, key, {
  auth: {persistSession: false, autoRefreshToken: false, detectSessionInUrl: false},
});

Deno.serve(createHandler({
  async getUser(token: string) {
    const {data, error} = await admin.auth.getUser(token);
    return error ? null : data.user;
  },
  async isSessionActive(userId: string, sessionId: string) {
    const {data, error} = await admin.rpc('relay_account_deletion_session_active', {
      request_user: userId, request_session: sessionId,
    });
    if (error) throw new Error('Session validation unavailable.');
    return data === true;
  },
  async signOutEverywhere(token: string) {
    const {error} = await admin.auth.admin.signOut(token, 'global');
    if (error) throw new Error('Session revocation unavailable.');
  },
  async deleteUser(userId: string) {
    const {error} = await admin.auth.admin.deleteUser(userId, false);
    if (error) throw new Error('Account deletion unavailable.');
  },
}));
