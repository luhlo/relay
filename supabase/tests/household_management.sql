-- Synthetic random-id users only. Run in an isolated database after all Relay
-- migrations. Nothing targets real accounts; all fixtures and changes roll back.
begin;
create temporary table management_fixture(key text primary key,value uuid) on commit drop;
insert into management_fixture select key,gen_random_uuid() from unnest(array[
  'a','b','c','d','stranger','orphan','new','anonymous','solo_owner','solo_removed',
  'session_a','session_b','session_c','session_d','session_stranger','session_orphan','session_new',
  'session_anonymous','session_solo_owner','session_solo_removed','home_a','home_b','home_solo','mutation_a','mutation_new'
]) key;
create temporary table management_values(key text primary key,value jsonb) on commit drop;
grant select,insert,update on management_fixture,management_values to authenticated;

create function pg_temp.actor(actor text) returns void language plpgsql as $$
declare u uuid; s uuid;
begin
  select value into u from management_fixture where key=actor;
  select value into s from management_fixture where key='session_' || actor;
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'session_id',s,'role','authenticated',
    'email','untrusted-stale-claim@example.invalid','user_metadata',jsonb_build_object('role','owner'))::text,true);
end $$;
create function pg_temp.expect_error(statement text,expected_state text) returns void language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement;
  exception when others then
    if sqlstate<>expected_state then raise exception 'Expected SQLSTATE %, got %: %',expected_state,sqlstate,sqlerrm; end if;
    rejected:=true;
  end;
  if not rejected then raise exception 'Expected SQLSTATE %, but statement succeeded: %',expected_state,statement; end if;
end $$;

do $$
declare f record;
begin
  for f in select key,value from management_fixture where key=any(array['a','b','c','d','stranger','orphan','new','anonymous','solo_owner','solo_removed']) loop
    insert into auth.users(id,email,is_anonymous) values(f.value,'management-' || f.value || '@example.invalid',f.key='anonymous');
    insert into auth.sessions(id,user_id,created_at) select value,f.value,now() from management_fixture where key='session_' || f.key;
  end loop;
  insert into public.households(id,name,child_one,child_two,child_names,caregiver_total)
    select value,'Family A','A1','A2',array['A1','A2'],4 from management_fixture where key='home_a';
  insert into public.households(id,name,child_one,child_two,child_names,caregiver_total)
    select value,'Family B','B1','Baby 2',array['B1'],2 from management_fixture where key='home_b';
  insert into public.households(id,name,child_one,child_two,child_names,caregiver_total)
    select value,'Solo family','S1','Baby 2',array['S1'],2 from management_fixture where key='home_solo';
  insert into public.household_members(user_id,household_id,display_name,role)
    select u.value,h.value,'Synthetic ' || u.key,case when u.key=any(array['a','b','d','solo_owner']) then 'owner' else 'caregiver' end
    from management_fixture u join management_fixture h on h.key=case
      when u.key=any(array['a','c','d']) then 'home_a'
      when u.key=any(array['b','stranger']) then 'home_b'
      else 'home_solo' end
    where u.key=any(array['a','b','c','d','stranger','solo_owner','solo_removed']);
  insert into public.parent_records(user_id) select user_id from public.household_members;
  update public.parent_records set payload=jsonb_build_object('version',2,'childNames',jsonb_build_array('A1','A2'),
    'shifts','[]'::jsonb,'sessions',jsonb_build_array(jsonb_build_object('shiftId',11,'kind','point','baby','both',
      'start','2026-11-24T12:00:00.000Z','end',null,'interruptions','[]'::jsonb)))
    where user_id=(select value from management_fixture where key='a');
  update public.parent_records set payload=jsonb_build_object('version',2,'childNames',jsonb_build_array('A1','A2'),
    'shifts','[]'::jsonb,'sessions',jsonb_build_array(jsonb_build_object('shiftId',12,'kind','point','baby','luca',
      'start','2026-11-23T12:00:00.000Z','end','2026-11-23T13:00:00.000Z','interruptions','[]'::jsonb)))
    where user_id=(select value from management_fixture where key='c');
end $$;

set local role authenticated;
select pg_temp.actor('c');
select pg_temp.expect_error('select public.relay_update_household_children(array[''No''])','42501');
select pg_temp.expect_error('select * from public.relay_list_household_invites()','42501');
select pg_temp.expect_error('select public.relay_invite_member(''person@example.invalid'',''caregiver'')','42501');
select pg_temp.expect_error('select public.relay_update_household_name(''Not yours'')','42501');
select pg_temp.expect_error('select * from relay_household_private.record_archives','42501');
select pg_temp.expect_error('select relay_household_private.attach_member(null,null,null,null,null)','42501');

select pg_temp.actor('a');
select pg_temp.expect_error('select public.relay_update_household_children(null)','22023');
select pg_temp.expect_error('select public.relay_update_household_children(array[]::text[])','22023');
select pg_temp.expect_error('select public.relay_update_household_children(array_fill(''n''::text,array[9]))','22023');
select pg_temp.expect_error('select public.relay_update_household_children(array[repeat(''x'',41)])','22023');
select pg_temp.expect_error('select public.relay_update_household_children(array[[''a'',''b''],[''c'',''d'']])','22023');
select pg_temp.expect_error('select public.relay_invite_member(null,''caregiver'')','22023');
select pg_temp.expect_error('select public.relay_invite_member(''bad email@example.invalid'',''caregiver'')','22023');
select pg_temp.expect_error('select public.relay_invite_member(''person@example.invalid'',null)','22023');
select pg_temp.expect_error('select public.relay_invite_member(''person@example.invalid'',''owner'')','22023');
select pg_temp.expect_error(format('select public.relay_remove_household_member(%L::uuid)',(select value from management_fixture where key='a')),'42501');
select pg_temp.expect_error(format('select public.relay_remove_household_member(%L::uuid)',(select value from management_fixture where key='d')),'42501');
select pg_temp.expect_error(format('select public.relay_remove_household_member(%L::uuid)',(select value from management_fixture where key='stranger')),'42501');

do $$
declare result text[]; payload jsonb; rev bigint; input jsonb; response jsonb; replay jsonb; old_snapshot jsonb;
  a uuid:=(select value from management_fixture where key='a'); home uuid:=(select value from management_fixture where key='home_a');
  mutation uuid:=(select value from management_fixture where key='mutation_a');
begin
  result:=public.relay_update_household_children(array[' A1 ',' ','Third']);
  if result<>array['A1','Baby 2','Third'] then raise exception 'Blank defaults/trim failed'; end if;
  if not exists(select 1 from public.households where id=home and child_names=result and child_one='A1' and child_two='Baby 2') then
    raise exception 'Child columns not synchronized';
  end if;
  select r.payload,r.revision into payload,rev from public.parent_records r where user_id=a;
  if payload#>'{sessions,0,careChildren}'<>'["chloe","luca"]'::jsonb or rev<>1 then
    raise exception 'Old active Both was not frozen using PRE-change child count';
  end if;
  if exists(select 1 from public.parent_records where user_id in (select value from management_fixture where key in ('c','d')) and revision<>0) then
    raise exception 'Unchanged records had revisions bumped';
  end if;
  perform public.relay_update_household_children(result);
  if (select revision from public.parent_records where user_id=a)<>1 then raise exception 'No-op children edit bumped revision'; end if;
  perform public.relay_update_household_children(array[null::text]);
  if not exists(select 1 from public.households where id=home and child_one='Baby 1' and child_two='Baby 2' and child_names=array['Baby 1']) then
    raise exception 'One-child legacy columns/defaults failed';
  end if;
  if (select r.payload#>'{sessions,0,careChildren}' from public.parent_records r where user_id=a)<>'["chloe","luca"]'::jsonb then
    raise exception 'Reducing count rewrote historical/active Both membership';
  end if;
  perform public.relay_update_household_children(array['A1','A2','Third','Fourth']);
  input:=payload #- '{sessions,0,careChildren}';
  input:=jsonb_set(input,'{childNames}','["A1","A2","Third","Fourth"]');
  if public.relay_save_records(1,input)<>2 then raise exception 'Ordinary legacy client stopped working'; end if;
  if (select r.payload#>'{sessions,0,careChildren}' from public.parent_records r where user_id=a)<>'["chloe","luca"]'::jsonb then
    raise exception 'Legacy save changed a stored Both snapshot';
  end if;
  input:=jsonb_set(input,'{childNames}','["A1","A2","Third"]');
  input:=jsonb_set(input,'{sessions}',(input->'sessions')||jsonb_build_array(jsonb_build_object('shiftId',13,'kind','point','baby','both',
    'start','2026-11-24T14:00:00.000Z','end','2026-11-24T14:30:00.000Z')));
  if public.relay_save_records(2,input)<>3 then raise exception 'New legacy Both save failed'; end if;
  if (select r.payload#>'{sessions,1,careChildren}' from public.parent_records r where user_id=a)<>'["chloe","luca","child3"]'::jsonb then
    raise exception 'New legacy Both ignored its queued payload child count';
  end if;
  input:=jsonb_set(input,'{childNames}','["A1","A2","Third","Fourth"]');
  input:=jsonb_set(input,'{sessions}',(input->'sessions')||jsonb_build_array(jsonb_build_object('shiftId',14,'kind','point','baby','both',
    'start','2026-11-24T15:00:00.000Z','end','2026-11-24T15:30:00.000Z','careChildren',jsonb_build_array('invalid'))));
  response:=public.relay_sync_records(3,mutation,input,home);
  if (response->>'applied_revision')::bigint<>4 or response#>'{payload,sessions,0,careChildren}'<>'["chloe","luca"]'::jsonb
    or response#>'{payload,sessions,2,careChildren}'<>'["chloe","luca","child3","child4"]'::jsonb then
    raise exception 'Scoped sync normalization failed';
  end if;
  perform public.relay_update_household_children(array['A1','A2','Third','Fourth','Fifth']);
  replay:=public.relay_sync_records(3,mutation,input,home);
  if (replay->>'applied_revision')::bigint<>4 or (replay->>'revision')::bigint<>4 then
    raise exception 'Raw retry after child-count change lost its original receipt';
  end if;
  response:=public.relay_sync_records(4,(select value from management_fixture where key='mutation_new'),response->'payload',home);
  replay:=public.relay_sync_records(3,mutation,input,home);
  if (replay->>'applied_revision')::bigint<>4 or (replay->>'revision')::bigint<>5 then
    raise exception 'Retry after newer writes did not return latest state plus original revision';
  end if;
  if replay#>'{payload,sessions,2,careChildren}'<>'["chloe","luca","child3","child4"]'::jsonb then
    raise exception 'Later metadata expanded a finished Both session';
  end if;
end $$;

-- Invitation retries are idempotent and a changed role invalidates old codes.
do $$
declare target_email text; token uuid; again uuid; replacement uuid; pending integer;
begin
  select 'management-' || value || '@example.invalid' into target_email from management_fixture where key='c';
  token:=public.relay_invite_member(target_email,'caregiver');
  again:=public.relay_invite_member(upper(target_email),'caregiver');
  if token<>again then raise exception 'Duplicate invitation request made another code'; end if;
  replacement:=public.relay_invite_member(target_email,'parent');
  if token=replacement then raise exception 'Changed role reused previous code'; end if;
  select count(*) into pending from public.relay_list_household_invites() i where i.email=target_email;
  if pending<>1 then raise exception 'Duplicate active invitations remain'; end if;
  insert into management_fixture values('old_c_invite',token),('pending_c_invite',replacement);
  select 'management-' || value || '@example.invalid' into target_email from management_fixture where key='orphan';
  token:=public.relay_invite_member(target_email,'caregiver');
  insert into management_fixture values('revoked_invite',token);
  perform public.relay_revoke_household_invite(token);
  perform public.relay_revoke_household_invite(token); -- retry is a no-op
  if exists(select 1 from public.relay_list_household_invites() i where i.code=token) then
    raise exception 'Revoked invite still listed';
  end if;
end $$;
select pg_temp.actor('orphan');
select pg_temp.expect_error(format('select public.relay_join_household(%L::uuid,''Orphan'')',(select value from management_fixture where key='revoked_invite')),'42501');

select pg_temp.actor('b');
do $$
declare token uuid;
begin
  token:=public.relay_invite_member('separate@example.invalid','caregiver');
  insert into management_fixture values('other_family_invite',token);
end $$;
select pg_temp.expect_error(format('select public.relay_revoke_household_invite(%L::uuid)',(select value from management_fixture where key='pending_c_invite')),'42501');
select pg_temp.expect_error(format('select public.relay_remove_household_member(%L::uuid)',(select value from management_fixture where key='c')),'42501');

select pg_temp.actor('a');
do $$
declare c uuid:=(select value from management_fixture where key='c');
begin
  if exists(select 1 from public.relay_list_household_invites() where code=(select value from management_fixture where key='other_family_invite')) then
    raise exception 'Another family invitation was disclosed';
  end if;
  perform public.relay_remove_household_member(c);
  if exists(select 1 from public.household_members where user_id=c) or exists(select 1 from public.parent_records where user_id=c) then
    raise exception 'Former family can still read removed caregiver membership/history';
  end if;
  if exists(select 1 from public.relay_list_household_invites() where code=(select value from management_fixture where key='pending_c_invite')) then
    raise exception 'Removal left an old pending rejoin code active';
  end if;
  perform public.relay_update_household_name('Family A changed after removal');
  perform public.relay_update_household_children(array['New child name']);
end $$;

select pg_temp.actor('c');
do $$
declare a uuid:=(select value from management_fixture where key='a');
  c uuid:=(select value from management_fixture where key='c'); archive record;
begin
  if not exists(select 1 from public.household_members where user_id=c and not is_active and household_id is null and deactivated_at is not null)
    or not exists(select 1 from public.parent_records where user_id=c and jsonb_array_length(payload->'sessions')=1) then
    raise exception 'Removal deleted or hid the person''s own records';
  end if;
  if exists(select 1 from public.parent_records where user_id=a) or exists(select 1 from public.households where id=(select value from management_fixture where key='home_a')) then
    raise exception 'Removed caregiver still has household access';
  end if;
  select * into archive from public.relay_list_personal_record_archives();
  if archive.id is null or archive.household_name<>'Family A' or cardinality(archive.child_names)<>5
    or archive.child_names[1]<>'A1' or not archive.is_current or jsonb_array_length(archive.payload->'sessions')<>1 then
    raise exception 'Removal archive missing or leaked newer household metadata';
  end if;
end $$;
select pg_temp.expect_error('select * from public.relay_list_household_invites()','42501');
select pg_temp.expect_error('select public.relay_update_household_children(array[''No''])','42501');
select pg_temp.expect_error(format('select public.relay_join_household(%L::uuid,''Removed caregiver'')',(select value from management_fixture where key='pending_c_invite')),'42501');
select pg_temp.expect_error(format('select public.relay_sync_records(0,gen_random_uuid(),''{"sessions":[],"shifts":[]}''::jsonb,%L::uuid)',(select value from management_fixture where key='home_a')),'42501');
select pg_temp.expect_error('select public.relay_save_records(0,''{"sessions":[],"shifts":[]}''::jsonb)','42501');

-- An intentional new invitation can restore membership, but never shares the
-- old household's history with the next household or replays old queued writes.
select pg_temp.actor('b');
do $$
declare token uuid; target_email text;
begin
  select 'management-' || value || '@example.invalid' into target_email from management_fixture where key='c';
  token:=public.relay_invite_member(target_email,'caregiver');
  insert into management_fixture values('new_c_invite',token);
end $$;
select pg_temp.actor('c');
do $$
declare home uuid; c uuid:=(select value from management_fixture where key='c'); archive record; response jsonb;
begin
  home:=public.relay_join_household((select value from management_fixture where key='new_c_invite'),'Caregiver C');
  if home<>(select value from management_fixture where key='home_b') then raise exception 'Joined wrong scope'; end if;
  if not exists(select 1 from public.parent_records where user_id=c and revision=1 and payload->'sessions'='[]'::jsonb and payload->'childNames'='["B1"]'::jsonb) then
    raise exception 'Joining a new family exposed old history or reused revision';
  end if;
  select * into archive from public.relay_list_personal_record_archives();
  if archive.id is null or archive.is_current or jsonb_array_length(archive.payload->'sessions')<>1 then
    raise exception 'Old private history not recoverable after rejoin';
  end if;
  response:=public.relay_sync_records(1,gen_random_uuid(),'{"sessions":[],"shifts":[],"childNames":["B1"]}'::jsonb,home);
  if (response->>'revision')::bigint<>2 then raise exception 'Scoped sync failed after rejoin'; end if;
end $$;
select pg_temp.expect_error(format('select public.relay_sync_records(2,gen_random_uuid(),''{"sessions":[],"shifts":[]}''::jsonb,%L::uuid)',(select value from management_fixture where key='home_a')),'42501');
select pg_temp.expect_error('select public.relay_save_records(2,''{"sessions":[],"shifts":[]}''::jsonb)','42501');
select pg_temp.expect_error('select public.relay_create_household_v2(''Cannot duplicate'',''C'',array[''Baby''],1)','42501');
select pg_temp.actor('b');
do $$
declare c uuid:=(select value from management_fixture where key='c');
begin
  if not exists(select 1 from public.parent_records where user_id=c and payload->'sessions'='[]'::jsonb)
    or exists(select 1 from public.relay_list_personal_record_archives()) then
    raise exception 'Next family received prior private records';
  end if;
end $$;
select pg_temp.expect_error(format('select public.relay_revoke_household_invite(%L::uuid)',(select value from management_fixture where key='new_c_invite')),'22023');
select public.relay_remove_household_member((select value from management_fixture where key='c'));
select pg_temp.actor('c');
do $$
declare home uuid; c uuid:=(select value from management_fixture where key='c');
begin
  home:=public.relay_create_household_v2('Caregiver''s new family','C',array[''],1);
  if (select count(*) from public.relay_list_personal_record_archives())<>2 then
    raise exception 'Multiple prior family histories were not preserved';
  end if;
  if not exists(select 1 from public.household_members where user_id=c and household_id=home and role='owner' and is_active)
    or not exists(select 1 from public.parent_records where user_id=c and revision=3 and payload->'sessions'='[]'::jsonb) then
    raise exception 'Creating a family after removal failed';
  end if;
end $$;

-- New accounts and the original create wrapper remain usable.
select pg_temp.actor('new');
select public.relay_create_household('Legacy new family','New user','','  ');

-- Live-session authorization applies to management and RLS, not editable
-- user_metadata, a stale JWT email, or the mere presence of an Auth UUID.
select pg_temp.actor('anonymous');
select pg_temp.expect_error('select * from public.relay_list_personal_record_archives()','28000');
select pg_temp.expect_error('select public.relay_create_household_v2(''No'',''No'',array[''No''],1)','28000');
select pg_temp.actor('c');
select set_config('request.jwt.claims',jsonb_build_object('sub',(select value from management_fixture where key='c'),
  'session_id',(select value from management_fixture where key='session_a'),'role','authenticated')::text,true);
do $$ begin
  if exists(select 1 from public.parent_records) or exists(select 1 from public.household_members) then
    raise exception 'Revoked or foreign session retained data access';
  end if;
end $$;
select pg_temp.expect_error('select * from public.relay_list_personal_record_archives()','28000');
select pg_temp.expect_error('select public.relay_update_household_children(array[''No''])','28000');

-- Removing a caregiver must not block later account/empty-household deletion.
select pg_temp.actor('solo_owner');
select public.relay_remove_household_member((select value from management_fixture where key='solo_removed'));
reset role;
do $$
declare gone_home uuid:=(select value from management_fixture where key='home_solo');
  removed uuid:=(select value from management_fixture where key='solo_removed');
  c uuid:=(select value from management_fixture where key='c');
begin
  delete from auth.users where id=(select value from management_fixture where key='solo_owner');
  if exists(select 1 from public.households where id=gone_home)
    or not exists(select 1 from public.parent_records where user_id=removed)
    or not exists(select 1 from relay_household_private.record_archives where user_id=removed and household_name='Solo family') then
    raise exception 'Removed membership prevented household deletion or lost private history';
  end if;
  delete from auth.users where id=c;
  if exists(select 1 from relay_household_private.record_archives where user_id=c)
    or exists(select 1 from public.household_members where user_id=c)
    or exists(select 1 from public.parent_records where user_id=c) then
    raise exception 'Account deletion left private archive data';
  end if;
  if has_table_privilege('authenticated','relay_household_private.record_archives','select')
    or has_table_privilege('anon','relay_household_private.record_archives','select')
    or has_function_privilege('anon','public.relay_remove_household_member(uuid)','execute')
    or has_function_privilege('authenticated','relay_household_private.attach_member(uuid,uuid,text,text,text[])','execute')
    or has_function_privilege('authenticated','relay_household_private.require_user()','execute') then
    raise exception 'Private household capability granted directly to client';
  end if;
end $$;

select 'Household ownership, session authorization, child snapshots, receipt replay, invitations, private archives, RLS and deletion checks passed' as result;
rollback;
