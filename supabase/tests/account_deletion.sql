-- Runs only synthetic, random-id accounts and always rolls back. Existing
-- accounts are never selected by the deletion predicates in this test.
begin;
do $$
declare
  owner_id uuid := gen_random_uuid();
  caregiver_id uuid := gen_random_uuid();
  third_id uuid := gen_random_uuid();
  household uuid := gen_random_uuid();
  session uuid := gen_random_uuid();
  expired_session uuid := gen_random_uuid();
  isolated_invite uuid := gen_random_uuid();
begin
  insert into auth.users(id,email) values
    (owner_id, 'relay-deletion-owner-' || owner_id || '@example.invalid'),
    (caregiver_id, 'relay-deletion-caregiver-' || caregiver_id || '@example.invalid'),
    (third_id, 'relay-deletion-third-' || third_id || '@example.invalid');
  insert into public.households(id,name,child_one,child_two,child_names,caregiver_total)
    values(household,'Deletion test only','Baby 1','Baby 2',array['Baby 1'],2);
  insert into public.household_members(user_id,household_id,display_name,role,joined_at) values
    (owner_id,household,'Test owner','owner',now()-interval '2 days'),
    (caregiver_id,household,'Test caregiver','caregiver',now()-interval '1 day');
  insert into public.parent_records(user_id) values(owner_id),(caregiver_id);
  insert into public.household_invites(household_id,email,created_by,accepted_by)
    values(household,'accepted@example.invalid',owner_id,caregiver_id);
  insert into public.household_invites(code,household_id,email,created_by,accepted_by)
    values(isolated_invite,household,'third@example.invalid',caregiver_id,third_id);
  insert into auth.sessions(id,user_id,created_at,not_after) values
    (session,owner_id,now(),null),
    (expired_session,owner_id,now()-interval '1 day',now()-interval '1 hour');

  if not public.relay_account_deletion_session_active(owner_id,session) then
    raise exception 'Live session rejected';
  end if;
  if public.relay_account_deletion_session_active(caregiver_id,session)
    or public.relay_account_deletion_session_active(owner_id,expired_session)
    or public.relay_account_deletion_session_active(owner_id,gen_random_uuid()) then
    raise exception 'Foreign, expired, or missing session accepted';
  end if;
  if has_function_privilege('anon','public.relay_account_deletion_session_active(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.relay_account_deletion_session_active(uuid,uuid)','execute')
    or not has_function_privilege('service_role','public.relay_account_deletion_session_active(uuid,uuid)','execute') then
    raise exception 'Session helper exposed to clients';
  end if;
  if has_schema_privilege('anon','relay_private','usage')
    or has_schema_privilege('authenticated','relay_private','usage') then
    raise exception 'Private helper schema exposed to clients';
  end if;

  delete from auth.users where id=owner_id;
  if exists(select 1 from public.household_members where user_id=owner_id)
    or exists(select 1 from public.parent_records where user_id=owner_id)
    or exists(select 1 from auth.sessions where user_id=owner_id) then
    raise exception 'Deleted account records remain';
  end if;
  if not exists(select 1 from public.household_members where user_id=caregiver_id and role='owner')
    or not exists(select 1 from public.parent_records where user_id=caregiver_id)
    or not exists(select 1 from public.households where id=household) then
    raise exception 'Surviving household data damaged or ownership not transferred';
  end if;

  delete from auth.users where id=third_id;
  if exists(select 1 from public.household_invites where code=isolated_invite) then
    raise exception 'Non-member accepted invitation prevents deletion';
  end if;
  delete from auth.users where id=caregiver_id;
  if exists(select 1 from public.households where id=household)
    or exists(select 1 from public.household_invites where household_id=household)
    or exists(select 1 from public.parent_records where user_id=caregiver_id) then
    raise exception 'Empty household was not removed';
  end if;
end $$;
select 'Account deletion synthetic transaction tests passed' as result;
rollback;
