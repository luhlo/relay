# Relay support and technical reports

This Edge Function collects voluntary feedback and allowlisted technical
diagnostics. It does not collect feature-use analytics. Guest collection needs
the existing public `apikey`; private reads additionally verify the Bearer
token with Supabase Auth and check the confirmed email against the service-only
`relay_support_admins` table. It never trusts `user_metadata` roles or an email
submitted in the request body. The initial report administrator is
`luhlostudios@gmail.com`.

## API

All calls are JSON POSTs to `/functions/v1/relay-support`. Client request keys
are camelCase; dashboard rows use database snake_case.

- Feedback: `{action:"feedback",category:"problem"|"idea"|"question",message,
  replyEmail?,appVersion,platform}`. Message is 10–2,000 characters; optional
  reply email is at most 254 characters. Returns HTTP 202 `{ok:true}`.
- Diagnostics: `{action:"diagnostic",eventType,code,operation?,durationMs?,
  appVersion,platform,fingerprint,frames}`. Only predefined exception classes,
  event types and operation identifiers are accepted. Frames contain at most
  ten `package:relay/...dart:line:column` locations, without method names,
  messages, full URLs, query parameters or user identifiers. Empty frames are
  allowed for minified web builds. Fingerprints are 8–64 lowercase hex digits
  grouping technical errors, not devices or people. Returns HTTP 202
  `{ok:true}`.
- Capabilities: `{action:"capabilities"}` returns `{canViewReports:true|false}`.
  Missing/invalid auth returns false. The public client key alone grants no
  report access.
- Dashboard: `{action:"dashboard"}` returns `{feedback:[...],diagnostics:[...],
  since:"ISO timestamp"}` for a verified report admin. It contains at most the
  latest 100 rows of each kind from the trailing 30 days. Others receive 403.

Bodies are bounded to 12 KiB of actual UTF-8 data, including streamed requests;
unknown fields are rejected. Requests need the public `apikey` currently used
by `lib/cloud.dart`. Supported platforms are `web`, `android`, `ios`, `linux`,
`macos`, `windows`, `fuchsia`, and `unknown`.

The CORS allowlist is `https://relay.luhlo.com` plus HTTP/HTTPS development
origins with the exact host `localhost` or `127.0.0.1`. Native requests without
Origin work normally. CORS and a publishable key are not admin authorization.

## Rate limits and retention

The service-only database limiter atomically checks both source-hour and
global-day counters: 5 feedback reports/hour/source, 30 diagnostics/hour/source,
and 2,000 total accepted reports/day. The edge handler HMACs a proxy-supplied
source address with a server-only secret before it enters the short-lived rate
table; raw addresses never enter report rows. Proxy addresses are abuse signals,
not identity or access-control credentials. Missing/unusable addresses share
an `unknown` limiter bucket rather than bypassing limits.

The migration schedules database-only daily cleanup with pg_cron: diagnostic
reports expire after 90 days, voluntary feedback after 180 days, and rate
buckets one day after their short window expires. These reports contain no
family/session payloads and have no foreign key to household or Auth data.

## Deploy and verify

1. Review/apply `20261119213330_relay_support_reports.sql` to the intended
   Supabase project. This creates service-only RLS tables and RPCs, and the
   `relay-support-retention` daily cron job.
2. Deploy `index.ts`, `handler.mjs`, and `deno.json` as `relay-support`, with
   `verify_jwt = false`. Guest collection uses the public key; Auth checks for
   private reads happen inside the handler. `SUPABASE_URL` and
   `SUPABASE_SERVICE_ROLE_KEY` remain in Supabase Edge environment secrets.
3. Run `node --test supabase/functions/relay-support/handler_test.mjs`.
4. Run `supabase/tests/support_reports.sql` against the target database. All
   synthetic changes and temporary limiter counters are rolled back.
5. Confirm guest capabilities are false, guest dashboard reads are forbidden,
   and a confirmed `luhlostudios@gmail.com` Relay account can open the dashboard.
6. Run database security advisors. Tables intentionally have RLS enabled and no
   client policies or grants; the service role is their only API caller.

The Edge code does not log request bodies, errors, credentials, tokens or source
addresses. Rate-limit rejection returns 429; temporary backend failure returns
a generic 503 and never blocks timer saving.
