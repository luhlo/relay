# Household management

Migration: `20261124215814_relay_household_management.sql`.

The migration adds owner-controlled child settings, pending invitation management,
and caregiver removal without deleting the caregiver's personal records. Apply
it together with clients that recognize inactive memberships and display private
record archives. It depends on the existing account-deletion and offline-sync
migrations. It was applied to Relay’s linked Supabase project on November 24, 2026, after validation.

## RPC contract

All calls require an authenticated, non-anonymous, live Supabase Auth session.
The server derives the caller's identity; no caller/owner id is accepted.

| RPC | Arguments | Result |
| --- | --- | --- |
| `relay_update_household_children` | `children text[]` | Cleaned `text[]` |
| `relay_list_household_invites` | None | Rows: `code`, `email`, `member_role`, `expires_at` |
| `relay_revoke_household_invite` | `invite_code uuid` | Void |
| `relay_remove_household_member` | `member_user_id uuid` | Void |
| `relay_list_personal_record_archives` | None | Own archive rows described below |

The first four require the current family owner. Child names accept one through
eight entries, trim spaces, default blanks/null entries to `Baby N`, and reject
names longer than 40 characters. The old `child_one`/`child_two` columns stay in
sync. Count changes freeze legacy Both sessions to their original child slots
using `careChildren` before changing metadata; only affected record payloads
receive a revision bump. Active Both sessions keep the children they started
with. The app's matching model change preserves those snapshots in calculations.

Invitation lists contain only pending, unexpired codes in the owner's family.
Revocation expires a code and is idempotent for an already-expired pending code.
An accepted code cannot be revoked: remove that member instead. Creating the
same pending email/role invitation again returns its existing code. Changing
the role expires previous pending codes for that email before creating a new
one. Accepting, revoking and issuing invitations serialize on the household and
invitation rows, so a revoked code cannot be accepted afterward.

## Removal and private recovery

Removal rejects self-removal, owner removal, cross-family targets and missing
members. It expires all pending invitations addressed to the removed person's
current Auth email within that family. This prevents an old unused code from
immediately restoring access. A new owner-created invitation can intentionally
restore membership later.

Before removing access, the transaction freezes a private copy of the person's
server record, revision, household name and child labels. It then marks their
membership `is_active=false`, sets `deactivated_at`, and sets `household_id=NULL`.
The membership owner row and `parent_records` are preserved; the destructive
membership-delete cascade is not invoked. Inactive members cannot access their
former family's metadata, members or other people's records, or sync changes to
that family. They can read their own record and private archive. Former peers
can no longer read the removed person's record.

`relay_list_personal_record_archives()` returns only the caller's snapshots:
`id uuid`, `household_id uuid`, `household_name text`, `child_names text[]`,
`payload jsonb`, `revision bigint`, `archived_at timestamptz`, `is_current boolean`.
`is_current` identifies the latest removal snapshot while the person remains
inactive. Labels are frozen in the archive; the RPC does not fetch current
metadata from a former household. The client displays snapshots read-only at
`archived_at`, so an originally open timer does not keep gaining time in a
historical view. No client role has direct access to the private archive table.

Joining or creating a family after removal reactivates the same member owner
row and starts a fresh shared record with the new family's child labels. The
record revision increases, old mutation receipts are cleared, and the old
snapshot remains privately recoverable through the archive RPC. Old records
are never automatically shared with the next family. Old queued writes with
the previous expected household id are rejected. Other copies already viewed
or saved on devices cannot be remotely erased by changing server permissions.

The legacy `relay_save_records` continues to work for ordinary active users.
It rejects inactive users and requires an updated app after a removal/rejoin,
because that older API cannot bind a write to a household id. The newer scoped
`relay_sync_records` continues to work after joining the new family. Both save
paths preserve stored Both snapshots when older clients omit `careChildren`.
Scoped sync receipts hash the original request before normalization, so a
retry stays idempotent even after child changes or later accepted writes.

Deleting an Auth account still deletes its private records and archives through
cascades. Unlinking inactive members also lets the last active account's existing
deletion trigger remove an empty household without reactivating former members.

## Locking and verification

Management writes acquire required Auth user `FOR KEY SHARE` locks before
household/invitation/member/record locks. The target Auth user is prelocked before
an archive FK is inserted, and the inviting/accepting user's Auth row is
prelocked before invitation/member FKs. Both record-save paths use the same
Auth-before-member-before-record order. This avoids inversions with the existing
Auth account-deletion trigger; that trigger is unchanged.

`supabase/tests/household_management.sql` exercises owner/session authorization,
child validation and history snapshots, raw mutation replay after metadata/newer
writes, invitation retries/revocation, private recovery, rejoining a different
family, stale-write rejection, RLS, and account/empty-household deletion. It uses
only synthetic random-id users and rolls back. Run it in an isolated test
Supabase/Postgres database after the migrations, not against real family data.

Validation on 2026-11-24:

- Household, account-deletion and offline-sync SQL suites passed in isolated
  PGlite and native PostgreSQL 17.10.
- Ten bounded two-connection native PostgreSQL races passed: both orders of
  caregiver removal/account deletion, owner invitation/account deletion,
  invite acceptance/revocation, child editing/scoped sync, and removal/caregiver
  sync. Each blocked transaction was observed waiting on a PostgreSQL lock and
  completed after the first committed, with only the expected permission,
  accepted-invite or revision-conflict outcome. No deadlock or lock timeout.
- A synthetic normalization of 10,000 Both sessions completed in about 91 ms
  on the test machine; this is an observation, not a production latency promise.

No production account/member/invitation/history was modified during development
or validation. Live checks inspected schema/function metadata only. Post-deployment checks verified the five new public RPCs are invoker functions,
require authenticated access, and expose no direct archive-table access to clients.
