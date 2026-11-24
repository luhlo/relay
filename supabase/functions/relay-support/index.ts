import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { createHandler, hashedRateBucket } from './handler.mjs';

const url = Deno.env.get('SUPABASE_URL');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if (!url || !serviceKey) throw new Error('Relay support backend is not configured.');

// This is Relay's existing public client key, not a credential for private reads.
const publishableKey = 'sb_publishable_K4HF2hnwtBwM196HRV_7ZQ_gxMKJkhD';
const admin = createClient(url, serviceKey, {
  auth: {persistSession: false, autoRefreshToken: false, detectSessionInUrl: false},
});

Deno.serve(createHandler({
  publishableKey,
  async getUser(token: string) {
    const {data, error} = await admin.auth.getUser(token);
    return error ? null : data.user;
  },
  async isAdmin(email: string) {
    const {data, error} = await admin.from('relay_support_admins').select('email').eq('email', email).maybeSingle();
    if (error) throw new Error('Report access unavailable.');
    return data !== null;
  },
  async rateBucket(req: Request) {
    return await hashedRateBucket(req, serviceKey);
  },
  async takeRate(bucket: string, kind: string) {
    const {data, error} = await admin.rpc('relay_support_take_rate', {
      request_bucket: bucket, request_kind: kind,
    });
    if (error) throw new Error('Report limits unavailable.');
    return data === true;
  },
  async saveFeedback(record: Record<string, unknown>) {
    const {error} = await admin.from('relay_support_feedback').insert(record);
    if (error) throw new Error('Feedback unavailable.');
  },
  async saveDiagnostic(record: Record<string, unknown>) {
    const {error} = await admin.from('relay_technical_reports').insert(record);
    if (error) throw new Error('Diagnostics unavailable.');
  },
  async dashboard(since: string) {
    const [feedback, diagnostics] = await Promise.all([
      admin.from('relay_support_feedback')
        .select('id,category,message,reply_email,app_version,platform,created_at')
        .gte('created_at', since).order('created_at', {ascending: false}).limit(100),
      admin.from('relay_technical_reports')
        .select('id,event_type,code,operation,duration_ms,app_version,platform,fingerprint,frames,created_at')
        .gte('created_at', since).order('created_at', {ascending: false}).limit(100),
    ]);
    if (feedback.error || diagnostics.error) throw new Error('Report dashboard unavailable.');
    return {feedback: feedback.data, diagnostics: diagnostics.data};
  },
}));
