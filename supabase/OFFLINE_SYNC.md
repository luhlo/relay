# Signed-in offline synchronization

The additive migration `20261119221944_relay_offline_sync.sql` leaves the
existing `relay_save_records` RPC unchanged for older Play/PWA versions.

## Request and response

`relay_sync_records(expected_revision bigint, mutation_id uuid,
new_payload jsonb, expected_household_id uuid)` returns JSON:

```json
{"applied_revision": 8, "revision": 9, "payload": {"sessions": [], "shifts": []}}
```

`applied_revision` is the revision at which that exact mutation was accepted.
`revision` and `payload` are the current server record, which can be newer after
another device saves. The owner comes from Auth; no user ID is accepted in the
request. The household ID must match the cached queue's original household.

Save the mutation UUID and its exact payload locally before sending. After a
timeout, retry that same UUID and payload. Sending a different payload with an
already accepted UUID is rejected. Preserve any local edits made while a request
is in flight; an acknowledgement is not permission to replace those edits.

## Authorization and conflicts

The public RPC is SECURITY INVOKER. Its unexposed implementation verifies an
actual nonanonymous Auth user, an active Auth session from the JWT session ID,
current membership and household scope, and the user's own parent-record row.
Membership is locked FOR SHARE before the record is locked FOR UPDATE. This
blocks household reassignment and follows the account-deletion lock order.

SQLSTATEs:

- `40001`: an unseen mutation's base revision changed; fetch and reconcile the
  current server data before retrying with a new mutation ID.
- `42501`: household membership/scope or the owner record changed; preserve the
  local queue and require the user to reconnect to the correct household.
- `28000`: user/session is missing, anonymous, expired or revoked; keep the queue
  and ask the same account to sign in again.
- `22023`: invalid body/revision/scope or mutation ID reused with other content.

Replaying an accepted mutation does not restore its old payload or increment the
revision again. It returns the current record even if an old client has since
used `relay_save_records` to make another change. Both paths lock the same row.

## Receipt storage and retention

`relay_sync_private.mutation_receipts` stores only owner ID, mutation UUID,
SHA-256 payload hash, accepted revision and timestamp. It stores no extra copy
of the family payload. RLS is enabled, and client table privileges are revoked.
The new private schema does not change the account-deletion helper schema.

Receipts reference `parent_records(user_id)` ON DELETE CASCADE, so deletion of
membership or Auth removes them through the existing cascade chain. An extra
Auth-user foreign key is deliberately avoided: it could deadlock against the
existing account-deletion trigger while a sync holds the record lock.

The `relay-offline-receipt-retention` cron job deletes receipts older than 90
days. An expired receipt cannot permit a blind replay: its old expected revision
still fails optimistic concurrency if the server has moved on. The client must
reconcile or surface a conflict. Pending local work is never deleted by this job.

## Validation

Review/apply the migration to the intended project, then run
`supabase/tests/offline_sync.sql`. It creates only random synthetic accounts and
always rolls back. It checks role grants/RLS, normal writes, lost replies,
duplicate IDs, changed-payload replays, optimistic conflicts, old-client writes,
wrong-household queues, cross-account isolation, invalid sessions, anonymous
users, departing/rejoining membership, account deletion and receipt retention.

Run database advisors after deployment. The private receipt table intentionally
has no client policies; its guarded function is the only user write path.

## Android background synchronization

Widget and lock-screen actions commit to the account's local cache first. Their
WorkManager action queue has no network requirement. A separate account-scoped
queue with a connected-network constraint opens the same cached account context
and drains its outbox through `relay_sync_records`.

The network worker never publishes a widget snapshot. It only reports pending
or blocked status and broadcasts a foreground reload request. Native pending
flags carry a monotonically increasing generation; a completion cannot clear a
newer local save, a different account, or a sign-out/re-entry generation. A
foreground snapshot that observed an empty outbox also cannot clear a newer
widget's pending signal. Conflicts and sign-in issues retain the local outbox
and request review in Relay. Transient failures have bounded exponential retries.
