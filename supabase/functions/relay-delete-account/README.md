# Relay account deletion

`POST /functions/v1/relay-delete-account` requires a signed-in user's bearer token
and exactly `{"confirmation":"DELETE"}`. No account id is accepted from callers.
Success is HTTP 200 with `{"deleted":true}`. The app asks for explicit final
confirmation before invoking this endpoint.

The function uses Supabase Auth `getUser(token)` to verify identity, then checks
the token's session id against `auth.sessions` through a service-only RPC. It
revokes all sessions before asking Auth Admin to hard-delete that same user.
Only Supabase's Edge environment supplies `SUPABASE_SERVICE_ROLE_KEY`; never
copy a secret/service-role key into Flutter, web assets, GitHub, or this folder.

The project uses ES256 signing. `verify_jwt = false` is intentional for Edge's
legacy JWT gateway compatibility: authentication is required and enforced in
the handler itself. Unauthenticated/invalid requests return 401. Keep this
mode paired with the Auth and live-session checks; do not remove either.

The migration installs a private BEFORE DELETE trigger on `auth.users`. Within
the same transaction it removes the departing account's member/profile row,
record snapshot and invitations (including invitations addressed to its email).
If other members remain, their accounts and records remain and the oldest
member becomes owner when needed. If nobody remains, it removes the household,
child names and remaining invitations. A failure rolls back Auth deletion and
cleanup together. An error after session revocation can require signing in
again before retrying.

No Supabase Storage objects are created by Relay. Local-only device history
and copies on another person's device are independent of this cloud deletion;
client cleanup clears the active signed-in widget/session on this device.

## Verification

Run `deno check index.ts` and `deno run handler_test.mjs` from this folder.
`deno.lock` pins the server client and dependencies. Handler tests cover success,
required confirmation, forbidden account-id input, identity/session mismatch,
expired/revoked tokens, methods, malformed/oversized bodies and backend failures.

`supabase/tests/account_deletion.sql` is a synthetic transaction suite. Run it
only against an isolated database with Relay's migrations and mock Auth schema,
or an expressly authorized test Supabase project. It generates random fake
users with `example.invalid` emails and always rolls back. It tests ownership
transfer, preserving other records, empty-household cleanup, invitation FKs,
sessions and grants. No real Relay account was deleted during validation.

Deployment: upload index.ts, handler.mjs, deno.json and deno.lock as the
`relay-delete-account` Edge Function after applying the migration.
