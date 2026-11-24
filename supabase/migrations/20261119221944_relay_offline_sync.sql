begin;

-- Keep privileged implementation and receipt data out of the exposed API
-- schema. Do not broaden access to the existing account-deletion helpers.
create schema relay_sync_private;
revoke all on schema relay_sync_private from public, anon, authenticated;
grant usage on schema relay_sync_private to authenticated, service_role;

create table relay_sync_private.mutation_receipts (
  owner_id uuid not null references public.parent_records(user_id) on delete cascade,
  mutation_id uuid not null,
  payload_hash text not null check (payload_hash ~ '^[a-f0-9]{64}$'),
  applied_revision bigint not null check (applied_revision > 0),
  created_at timestamptz not null default statement_timestamp(),
  primary key (owner_id, mutation_id)
);
create index mutation_receipts_created_at
  on relay_sync_private.mutation_receipts (created_at);
alter table relay_sync_private.mutation_receipts enable row level security;
revoke all on relay_sync_private.mutation_receipts from public, anon, authenticated;
grant select, insert, update, delete on relay_sync_private.mutation_receipts to service_role;

-- SECURITY DEFINER is needed only for the internal implementation: clients
-- cannot write parent_records or access receipts directly. Every call verifies
-- an actual Auth session, its user, household scope, and owner row before writes.
create function relay_sync_private.sync_records(
  expected_revision bigint,
  mutation_id uuid,
  new_payload jsonb,
  expected_household_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  request_user uuid := auth.uid();
  request_session uuid;
  current_household uuid;
  current_record public.parent_records%rowtype;
  previous_receipt relay_sync_private.mutation_receipts%rowtype;
  incoming_hash text;
begin
  if request_user is null then
    raise exception 'Sign in before syncing your saved changes.' using errcode = '28000';
  end if;
  begin
    request_session := nullif(auth.jwt()->>'session_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Sign in again before syncing your saved changes.' using errcode = '28000';
  end;
  if not exists (
    select 1 from auth.users u
    where u.id = request_user and u.deleted_at is null
      and not coalesce(u.is_anonymous, false)
  ) or request_session is null or not exists (
    select 1 from auth.sessions s
    where s.id = request_session and s.user_id = request_user
      and (s.not_after is null or s.not_after > statement_timestamp())
  ) then
    raise exception 'Sign in again before syncing your saved changes.' using errcode = '28000';
  end if;

  if expected_revision is null or expected_revision < 0 or mutation_id is null
    or expected_household_id is null then
    raise exception 'Invalid sync request.' using errcode = '22023';
  end if;
  if jsonb_typeof(new_payload) is distinct from 'object'
    or jsonb_typeof(new_payload->'sessions') is distinct from 'array'
    or jsonb_typeof(new_payload->'shifts') is distinct from 'array'
    or octet_length(new_payload::text) > 10000000 then
    raise exception 'Invalid saved records.' using errcode = '22023';
  end if;

  -- Membership is locked first, matching deletion's member -> record order.
  -- FOR SHARE also blocks a concurrent household_id reassignment; KEY SHARE
  -- would protect only the membership's key and would not protect this scope.
  select m.household_id into current_household
    from public.household_members m
    where m.user_id = request_user
    for share;
  if current_household is null or current_household <> expected_household_id then
    raise exception 'Your household changed. Reconnect before syncing these saved changes.'
      using errcode = '42501';
  end if;

  select r.* into current_record from public.parent_records r
    where r.user_id = request_user for update;
  if current_record.user_id is null then
    raise exception 'Your saved-record account is unavailable. Reconnect before syncing.'
      using errcode = '42501';
  end if;

  incoming_hash := encode(extensions.digest(new_payload::text, 'sha256'), 'hex');
  select mr.* into previous_receipt from relay_sync_private.mutation_receipts mr
    where mr.owner_id = request_user and mr.mutation_id = sync_records.mutation_id;
  if previous_receipt.owner_id is not null then
    if previous_receipt.payload_hash <> incoming_hash then
      raise exception 'This saved-change identifier was already used for different records.'
        using errcode = '22023';
    end if;
    -- A reply can be lost, followed by successful writes from another device.
    -- Return the current record as well as the original accepted revision.
    return jsonb_build_object(
      'applied_revision', previous_receipt.applied_revision,
      'revision', current_record.revision,
      'payload', current_record.payload
    );
  end if;

  if current_record.revision <> expected_revision then
    raise exception 'Your records changed on another device. Review before syncing.'
      using errcode = '40001';
  end if;
  update public.parent_records r
    set payload = new_payload, revision = r.revision + 1,
        updated_at = statement_timestamp()
    where r.user_id = request_user
    returning r.* into current_record;
  insert into relay_sync_private.mutation_receipts
    (owner_id, mutation_id, payload_hash, applied_revision)
    values (request_user, mutation_id, incoming_hash, current_record.revision);
  return jsonb_build_object(
    'applied_revision', current_record.revision,
    'revision', current_record.revision,
    'payload', current_record.payload
  );
end;
$$;
revoke all on function relay_sync_private.sync_records(bigint,uuid,jsonb,uuid)
  from public, anon, authenticated, service_role;
grant execute on function relay_sync_private.sync_records(bigint,uuid,jsonb,uuid)
  to authenticated;

-- Public, invoker-only entrypoint. No owner/account identifier can be supplied
-- by a client; the private helper derives it from the verified Auth claims.
create function public.relay_sync_records(
  expected_revision bigint,
  mutation_id uuid,
  new_payload jsonb,
  expected_household_id uuid
) returns jsonb
language sql security invoker set search_path = '' as $$
  select relay_sync_private.sync_records(
    expected_revision, mutation_id, new_payload, expected_household_id
  );
$$;
revoke all on function public.relay_sync_records(bigint,uuid,jsonb,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.relay_sync_records(bigint,uuid,jsonb,uuid)
  to authenticated;

create function relay_sync_private.expire_mutation_receipts() returns bigint
language plpgsql security invoker set search_path = '' as $$
declare removed bigint;
begin
  delete from relay_sync_private.mutation_receipts
    where created_at < statement_timestamp() - interval '90 days';
  get diagnostics removed = row_count;
  return removed;
end;
$$;
revoke all on function relay_sync_private.expire_mutation_receipts()
  from public, anon, authenticated;
grant execute on function relay_sync_private.expire_mutation_receipts() to service_role;

-- pg_cron is already available for support-report retention. This only removes
-- deduplication hashes, not family records, account data, or pending local work.
select cron.schedule(
  'relay-offline-receipt-retention', '27 4 * * *',
  'select relay_sync_private.expire_mutation_receipts();'
);

commit;
