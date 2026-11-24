-- Synthetic fixtures only. All account, record, receipt and quota changes roll
-- back; no existing user's records are selected, printed, or modified.
begin;

create temporary table relay_sync_fixture (
  owner_id uuid, other_id uuid, anonymous_id uuid, no_member_id uuid,
  household_id uuid, other_household_id uuid,
  session_id uuid, other_session_id uuid, anonymous_session_id uuid,
  no_member_session_id uuid, expired_session_id uuid,
  first_mutation uuid, second_mutation uuid, old_mutation uuid
) on commit drop;
insert into relay_sync_fixture values (
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
);
grant select on relay_sync_fixture to authenticated;

do $$
declare f relay_sync_fixture%rowtype;
begin
  select * into f from relay_sync_fixture;
  insert into auth.users(id,email,is_anonymous) values
    (f.owner_id,'relay-sync-owner-' || f.owner_id || '@example.invalid',false),
    (f.other_id,'relay-sync-other-' || f.other_id || '@example.invalid',false),
    (f.anonymous_id,null,true),
    (f.no_member_id,'relay-sync-no-member-' || f.no_member_id || '@example.invalid',false);
  insert into public.households(id,name,child_one,child_two,child_names,caregiver_total) values
    (f.household_id,'Synthetic sync home','Baby 1','Baby 2',array['Baby 1'],2),
    (f.other_household_id,'Synthetic other home','Baby 1','Baby 2',array['Baby 1'],1);
  insert into public.household_members(user_id,household_id,display_name,role) values
    (f.owner_id,f.household_id,'Synthetic owner','owner'),
    (f.other_id,f.household_id,'Synthetic second member','parent'),
    (f.anonymous_id,f.other_household_id,'Synthetic anonymous member','owner');
  insert into public.parent_records(user_id) values(f.owner_id),(f.other_id),(f.anonymous_id);
  insert into auth.sessions(id,user_id,created_at,not_after) values
    (f.session_id,f.owner_id,now(),null),
    (f.other_session_id,f.other_id,now(),null),
    (f.anonymous_session_id,f.anonymous_id,now(),null),
    (f.no_member_session_id,f.no_member_id,now(),null),
    (f.expired_session_id,f.owner_id,now()-interval '2 days',now()-interval '1 day');

  if has_table_privilege('authenticated','relay_sync_private.mutation_receipts','select')
    or has_table_privilege('anon','relay_sync_private.mutation_receipts','select')
    or has_table_privilege('authenticated','relay_sync_private.mutation_receipts','insert')
    or has_table_privilege('authenticated','relay_sync_private.mutation_receipts','update')
    or has_table_privilege('authenticated','relay_sync_private.mutation_receipts','delete') then
    raise exception 'Private sync receipts exposed to client roles';
  end if;
  if has_function_privilege('anon','public.relay_sync_records(bigint,uuid,jsonb,uuid)','execute')
    or not has_function_privilege('authenticated','public.relay_sync_records(bigint,uuid,jsonb,uuid)','execute')
    or has_function_privilege('authenticated','relay_sync_private.expire_mutation_receipts()','execute') then
    raise exception 'Sync function privileges are incorrect';
  end if;
  if (select p.prosecdef from pg_proc p where p.oid='public.relay_sync_records(bigint,uuid,jsonb,uuid)'::regprocedure) then
    raise exception 'Public sync wrapper must be SECURITY INVOKER';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='relay_sync_private' and c.relname='mutation_receipts' and c.relrowsecurity
  ) then raise exception 'Sync receipts are missing RLS'; end if;
  if has_schema_privilege('authenticated','relay_private','usage') then
    raise exception 'Existing account-deletion private schema permissions changed';
  end if;
end;
$$;

set local role authenticated;
do $$
declare
  f relay_sync_fixture%rowtype;
  first_payload jsonb := '{"version":4,"alerts":true,"shifts":[],"sessions":[]}'::jsonb;
  second_payload jsonb := '{"version":4,"alerts":false,"shifts":[],"sessions":[]}'::jsonb;
  reply jsonb;
begin
  select * into f from relay_sync_fixture;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.owner_id,'role','authenticated','session_id',f.session_id)::text,true);
  reply := public.relay_sync_records(0,f.first_mutation,first_payload,f.household_id);
  if reply->>'applied_revision' <> '1' or reply->>'revision' <> '1'
    or reply->'payload' <> first_payload then raise exception 'Initial sync failed'; end if;

  -- Repeating the exact request after a lost reply must not increment revision.
  reply := public.relay_sync_records(0,f.first_mutation,first_payload,f.household_id);
  if reply->>'applied_revision' <> '1' or reply->>'revision' <> '1' then
    raise exception 'Lost acknowledgement replay applied twice';
  end if;

  begin
    perform public.relay_sync_records(0,f.first_mutation,second_payload,f.household_id);
    raise exception 'Mutation identifier reused with different payload';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.relay_sync_records(0,gen_random_uuid(),second_payload,f.household_id);
    raise exception 'Stale unseen mutation accepted';
  exception when sqlstate '40001' then null;
  end;

  -- Old clients remain compatible, and a receipt replay returns their CURRENT
  -- record rather than restoring the old accepted payload.
  if public.relay_save_records(1,second_payload) <> 2 then
    raise exception 'Legacy write compatibility failed';
  end if;
  reply := public.relay_sync_records(0,f.first_mutation,first_payload,f.household_id);
  if reply->>'applied_revision' <> '1' or reply->>'revision' <> '2'
    or reply->'payload' <> second_payload then
    raise exception 'Receipt replay did not return current server state';
  end if;

  begin
    perform public.relay_sync_records(2,gen_random_uuid(),first_payload,f.other_household_id);
    raise exception 'Wrong household accepted';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),first_payload,null);
    raise exception 'Missing household scope accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.relay_sync_records(-1,gen_random_uuid(),first_payload,f.household_id);
    raise exception 'Negative revision accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),null,f.household_id);
    raise exception 'Missing payload accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),'{"sessions":{},"shifts":[]}',f.household_id);
    raise exception 'Malformed payload accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform 1 from relay_sync_private.mutation_receipts where owner_id=f.owner_id;
    raise exception 'Client could read its private mutation receipts';
  exception when insufficient_privilege then null;
  end;

  -- A different member may use the same UUID for THEIR row only. The client
  -- cannot provide a victim user_id or cause the owner's record to change.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.other_id,'role','authenticated','session_id',f.other_session_id)::text,true);
  reply := public.relay_sync_records(0,f.first_mutation,first_payload,f.household_id);
  if reply->>'revision' <> '1' then raise exception 'Second owner sync failed'; end if;
  begin
    perform public.relay_sync_records(1,gen_random_uuid(),second_payload,f.other_household_id);
    raise exception 'Second owner crossed household scope';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.owner_id,'role','authenticated','session_id',f.expired_session_id)::text,true);
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),first_payload,f.household_id);
    raise exception 'Expired session accepted';
  exception when sqlstate '28000' then null;
  end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.owner_id,'role','authenticated','session_id',f.other_session_id)::text,true);
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),first_payload,f.household_id);
    raise exception 'Foreign session accepted';
  exception when sqlstate '28000' then null;
  end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.owner_id,'role','authenticated')::text,true);
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),first_payload,f.household_id);
    raise exception 'Missing session accepted';
  exception when sqlstate '28000' then null;
  end;
  perform set_config('request.jwt.claims','{}',true);
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),first_payload,f.household_id);
    raise exception 'Missing Auth user accepted';
  exception when sqlstate '28000' then null;
  end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.anonymous_id,'role','authenticated','session_id',f.anonymous_session_id)::text,true);
  begin
    perform public.relay_sync_records(0,gen_random_uuid(),first_payload,f.other_household_id);
    raise exception 'Anonymous Auth user accepted';
  exception when sqlstate '28000' then null;
  end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.no_member_id,'role','authenticated','session_id',f.no_member_session_id)::text,true);
  begin
    perform public.relay_sync_records(0,gen_random_uuid(),first_payload,f.household_id);
    raise exception 'User without membership accepted';
  exception when sqlstate '42501' then null;
  end;
end;
$$;
reset role;

set local role anon;
do $$
begin
  begin
    perform public.relay_sync_records(0,gen_random_uuid(),'{"sessions":[],"shifts":[]}',gen_random_uuid());
    raise exception 'Anonymous role could execute the sync RPC';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;

do $$
declare
  f relay_sync_fixture%rowtype;
  reply jsonb;
begin
  select * into f from relay_sync_fixture;
  if (select revision from public.parent_records where user_id=f.owner_id) <> 2
    or (select count(*) from relay_sync_private.mutation_receipts where owner_id=f.owner_id) <> 1
    or (select count(*) from relay_sync_private.mutation_receipts where owner_id=f.other_id) <> 1 then
    raise exception 'Failed/foreign requests changed the owner record or created receipts';
  end if;
  insert into relay_sync_private.mutation_receipts(owner_id,mutation_id,payload_hash,applied_revision,created_at)
    values(f.owner_id,f.old_mutation,repeat('0',64),1,statement_timestamp()-interval '91 days');
  perform relay_sync_private.expire_mutation_receipts();
  if exists(select 1 from relay_sync_private.mutation_receipts where owner_id=f.owner_id and mutation_id=f.old_mutation)
    or not exists(select 1 from relay_sync_private.mutation_receipts where owner_id=f.owner_id and mutation_id=f.first_mutation) then
    raise exception 'Receipt retention boundaries failed';
  end if;
  -- Membership deletion removes receipts through the owned parent row. A later
  -- rejoin cannot turn an old household's pending request into a fresh write.
  delete from public.household_members where user_id=f.other_id;
  if exists(select 1 from relay_sync_private.mutation_receipts where owner_id=f.other_id) then
    raise exception 'Departed member receipt survived';
  end if;
  insert into public.household_members(user_id,household_id,display_name,role)
    values(f.other_id,f.other_household_id,'Synthetic rejoined member','parent');
  insert into public.parent_records(user_id) values(f.other_id);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.other_id,'role','authenticated','session_id',f.other_session_id)::text,true);
  begin
    perform public.relay_sync_records(0,gen_random_uuid(),'{"sessions":[],"shifts":[]}',f.household_id);
    raise exception 'Old-household offline queue overwrote rejoined record';
  exception when sqlstate '42501' then null;
  end;
  if (select revision from public.parent_records where user_id=f.other_id) <> 0 then
    raise exception 'Old-household scope changed new records';
  end if;
  delete from auth.sessions where id=f.session_id;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.owner_id,'role','authenticated','session_id',f.session_id)::text,true);
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),'{"sessions":[],"shifts":[]}',f.household_id);
    raise exception 'Revoked session accepted';
  exception when sqlstate '28000' then null;
  end;
  delete from auth.users where id=f.owner_id;
  if exists(select 1 from relay_sync_private.mutation_receipts where owner_id=f.owner_id) then
    raise exception 'Deleted account receipt survived';
  end if;
end;
$$;

set local role authenticated;
do $$
declare f relay_sync_fixture%rowtype;
begin
  select * into f from relay_sync_fixture;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',f.owner_id,'role','authenticated','session_id',f.session_id)::text,true);
  begin
    perform public.relay_sync_records(2,gen_random_uuid(),'{"sessions":[],"shifts":[]}',f.household_id);
    raise exception 'Deleted account could replay saved writes';
  exception when sqlstate '28000' then null;
  end;
end;
$$;
reset role;

select 'Offline sync ownership, household scope, idempotency, compatibility and retention checks passed' as result;
rollback;
