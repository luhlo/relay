# Relay cloud setup

Project: `mhfkjrtrfdnmjmmvlueg`. The base and family-onboarding migrations were applied on 2026-09-20. `20260921040221_update_household_name.sql` was applied through the Supabase migration API on 2026-09-20 (Central time).

## Design

- Supabase email/password authentication, verified email, password recovery.
- One household per account, with an owner and invited parents or caregivers. A family can configure one to eight child names; blank names become Baby 1, Baby 2, and so on.
- Parent tracking (shifts, sessions, interruption timestamps) is stored in a versioned JSON record per parent. Partners can read each other's Insights but cannot edit one another's records. The UI uses the current device timezone; timestamps are stored as UTC instants.
- Saves require a connection. There is no offline cloud write queue. Optimistic revision checks reject stale writes; Refresh reloads the server copy. An uncertain network result must be resolved by Refresh.
- Local SQLite/browser records stay separate. The import action copies local history only into an empty account, with confirmation; the original device copy remains unchanged.
- Invitations are email-bound UUID codes, valid for seven days and single use. The owner manually shares the code; Relay does not email invitation messages yet.
- All five tables have RLS. Clients can select permitted household records and execute validated RPCs. No client has direct table write access. There is no anonymous data access.
- `platform_admins` is empty by default. Admins can read household information; no public registration or metadata field grants that role. Assignment must be performed separately by the project operator after identifying the authorized account. The admin dashboard is deferred.
- Only the existing publishable key is included in the app. No privileged key is used.

## Launch prerequisites

1. Correct the Google OAuth web client's authorized redirect URI to `https://mhfkjrtrfdnmjmmvlueg.supabase.co/auth/v1/callback`, then complete a real Google sign-in.
2. Deploy the Flutter web build to GitHub Pages at `https://relay.luhlo.com/` and verify HTTPS.
3. Complete a real password reset on Android and web. Custom SMTP email delivery and account confirmation have already been verified.

Production Site URL: `https://relay.luhlo.com/`.
Allowed redirects: `app.relay.relay://login-callback`, `https://relay.luhlo.com/`, `http://127.0.0.1:8765/`, `http://localhost:8765/`.

## Database verification

Live SQL transaction tests used three synthetic users and rolled back all test records. Verified household creation/sharing, cross-household isolation, invitation email binding, stale revision rejection, parent write ownership, denied direct writes, denied admin escalation, and anonymous denial.

For reproducible client checks run `flutter analyze` and `flutter test`.
