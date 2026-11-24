begin;

-- A removed caregiver keeps their private record owner row; unlinking the
-- household revokes sharing without activating parent_records' delete cascade.
alter table public.household_members
  add column is_active boolean not null default true,
  add column deactivated_at timestamptz,
  alter column household_id drop not null;
alter table public.household_members add constraint household_members_active_scope
  check (
    (is_active and household_id is not null and deactivated_at is null)
    or (not is_active and household_id is null and deactivated_at is not null)
  );

create schema relay_household_private;
revoke all on schema relay_household_private from public, anon, authenticated;
grant usage on schema relay_household_private to authenticated, service_role;

-- Snapshots belong to the person, never to their next household. Metadata is
-- frozen at removal so a former caregiver cannot learn later family changes.
create table relay_household_private.record_archives (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  household_id uuid not null,
  household_name text not null,
  child_names text[] not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  revision bigint not null,
  archived_at timestamptz not null,
  unique(user_id, archived_at)
);
create index record_archives_user_time on relay_household_private.record_archives(user_id, archived_at desc);
alter table relay_household_private.record_archives enable row level security;
revoke all on relay_household_private.record_archives from public, anon, authenticated;
grant select, insert, update, delete on relay_household_private.record_archives to service_role;

create function relay_household_private.verified_user() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare request_user uuid := auth.uid(); request_session uuid;
begin
  if request_user is null then return null; end if;
  begin request_session := nullif(auth.jwt()->>'session_id','')::uuid;
  exception when invalid_text_representation then return null; end;
  if request_session is null or not exists (
    select 1 from auth.users u where u.id=request_user
      and u.deleted_at is null and not coalesce(u.is_anonymous,false)
  ) or not exists (
    select 1 from auth.sessions s where s.id=request_session and s.user_id=request_user
      and (s.not_after is null or s.not_after > statement_timestamp())
  ) then return null; end if;
  return request_user;
end $$;

create function relay_household_private.require_user() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare request_user uuid := relay_household_private.verified_user();
begin
  if request_user is null then
    raise exception 'Sign in again before changing your family.' using errcode='28000';
  end if;
  return request_user;
end $$;

-- Auth deletion takes the Auth user row before household rows. Prelock every
-- user that a management write may reference through an FK in the same order,
-- so a concurrent account deletion cannot form Auth-row <-> household deadlocks.
create function relay_household_private.lock_auth_user(request_user uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$
begin
  perform 1 from auth.users where id=request_user and deleted_at is null for key share;
  return found;
end $$;

create function relay_household_private.active_household() returns uuid
language sql stable security definer set search_path = '' as $$
  select household_id from public.household_members
    where user_id=relay_household_private.verified_user() and is_active;
$$;
create function relay_household_private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.platform_admins
    where user_id=relay_household_private.verified_user());
$$;

-- Pure normalization also protects pre-snapshot app versions. Once a session
-- has a careChildren snapshot, a later legacy save cannot expand it to new
-- children. During the children edit, force the pre-change household count.
create function relay_household_private.valid_care_snapshot(snapshot jsonb) returns jsonb
language plpgsql immutable security invoker set search_path = '' as $$
begin
  if jsonb_typeof(snapshot) is distinct from 'array' then return null; end if;
  if jsonb_array_length(snapshot) not between 1 and 8 then return null; end if;
  if exists(select 1 from jsonb_array_elements(snapshot) e where jsonb_typeof(e) is distinct from 'string'
    or not (e #>> '{}' = any(array['chloe','luca','child3','child4','child5','child6','child7','child8'])))
    or (select count(*)<>count(distinct e) from jsonb_array_elements(snapshot) e)
  then return null; end if;
  return snapshot;
end $$;

create function relay_household_private.normalize_care_children(
  input_payload jsonb, stored_payload jsonb, fallback_child_count integer,
  use_household_count boolean default false
) returns jsonb
language plpgsql immutable security invoker set search_path = '' as $$
declare
  old_sessions jsonb:='{}'::jsonb; result_sessions jsonb;
  child_count integer; supplied_count integer; default_snapshot jsonb;
  slots constant text[]:=array['chloe','luca','child3','child4','child5','child6','child7','child8'];
begin
  if jsonb_typeof(input_payload) is distinct from 'object'
    or jsonb_typeof(input_payload->'sessions') is distinct from 'array' then return input_payload; end if;
  child_count:=greatest(1,least(8,coalesce(fallback_child_count,1)));
  if not use_household_count and jsonb_typeof(input_payload->'childNames')='array' then
    supplied_count:=jsonb_array_length(input_payload->'childNames');
    if supplied_count between 1 and 8 then child_count:=supplied_count; end if;
  end if;
  default_snapshot:=to_jsonb(slots[1:child_count]);
  -- Index old sessions once. This avoids repeatedly scanning years of history
  -- for every Both session when a queued offline snapshot finally syncs.
  if jsonb_typeof(stored_payload->'sessions')='array' then
    select coalesce(jsonb_object_agg(jsonb_build_array(e->'start',e->'kind',e->'baby',e->'shiftId')::text,e),'{}'::jsonb)
      into old_sessions from jsonb_array_elements(stored_payload->'sessions') e;
  end if;
  select coalesce(jsonb_agg(case when jsonb_typeof(e)='object' and e->>'baby'='both' then
    jsonb_set(e,'{careChildren}',coalesce(
      relay_household_private.valid_care_snapshot(e->'careChildren'),
      relay_household_private.valid_care_snapshot((old_sessions->jsonb_build_array(e->'start',e->'kind',e->'baby',e->'shiftId')::text)->'careChildren'),
      default_snapshot
    ),true) else e end order by position),'[]'::jsonb)
    into result_sessions from jsonb_array_elements(input_payload->'sessions') with ordinality items(e,position);
  return jsonb_set(input_payload,'{sessions}',result_sessions,true);
end $$;

create function relay_household_private.clean_children(children text[]) returns text[]
language plpgsql immutable security invoker set search_path = '' as $$
declare cleaned text[];
begin
  if children is null or cardinality(children) not between 1 and 8
    or array_ndims(children) is distinct from 1 then
    raise exception 'Choose between 1 and 8 children.' using errcode='22023';
  end if;
  if exists(select 1 from unnest(children) value where char_length(btrim(coalesce(value,'')))>40) then
    raise exception 'Child names must be 40 characters or fewer.' using errcode='22023';
  end if;
  select array_agg(coalesce(nullif(btrim(value),''),'Baby ' || position) order by position)
    into cleaned from unnest(children) with ordinality names(value,position);
  return cleaned;
end $$;

-- All family administration uses household -> invite/member -> record locks.
-- Recheck ownership after taking the household lock, including deletion races.
create function relay_household_private.lock_owned_household() returns uuid
language plpgsql security definer set search_path = '' as $$
declare request_user uuid:=relay_household_private.require_user(); home uuid;
begin
  if not relay_household_private.lock_auth_user(request_user) then
    raise exception 'Sign in again before changing your family.' using errcode='28000';
  end if;
  select household_id into home from public.household_members
    where user_id=request_user and is_active and role='owner';
  if home is null then
    raise exception 'Only the family owner can make this change.' using errcode='42501';
  end if;
  perform 1 from public.households where id=home for update;
  perform 1 from public.household_members where user_id=request_user
    and household_id=home and is_active and role='owner' for share;
  if not found then
    raise exception 'Your family membership changed. Refresh and try again.' using errcode='42501';
  end if;
  return home;
end $$;

create function relay_household_private.update_children(children text[]) returns text[]
language plpgsql security definer set search_path = '' as $$
declare home uuid:=relay_household_private.lock_owned_household(); cleaned text[];
  old_names text[]; record public.parent_records%rowtype; normalized jsonb;
begin
  cleaned:=relay_household_private.clean_children(children);
  select child_names into old_names from public.households where id=home;
  if cleaned=old_names then return cleaned; end if;
  perform 1 from public.household_members where household_id=home and is_active order by user_id for share;
  for record in select r.* from public.parent_records r join public.household_members m on m.user_id=r.user_id
    where m.household_id=home and m.is_active order by r.user_id for update of r loop
    normalized:=relay_household_private.normalize_care_children(record.payload,'{}'::jsonb,cardinality(old_names),true);
    if normalized is distinct from record.payload then
      update public.parent_records set payload=normalized,revision=revision+1,updated_at=statement_timestamp()
        where user_id=record.user_id;
    end if;
  end loop;
  update public.households set child_names=cleaned,child_one=cleaned[1],
    child_two=coalesce(cleaned[2],'Baby 2') where id=home;
  return cleaned;
end $$;

create function relay_household_private.list_invites()
returns table(code uuid,email text,member_role text,expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare home uuid:=relay_household_private.lock_owned_household();
begin
  return query select i.code,i.email,i.member_role,i.expires_at from public.household_invites i
    where i.household_id=home and i.accepted_by is null and i.expires_at>statement_timestamp()
    order by i.expires_at,i.code;
end $$;

create function relay_household_private.revoke_invite(invite_code uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare home uuid:=relay_household_private.lock_owned_household(); invitation public.household_invites%rowtype;
begin
  select * into invitation from public.household_invites
    where code=invite_code and household_id=home for update;
  if invitation.code is null then
    raise exception 'This invitation is not in your family. Refresh and try again.' using errcode='42501';
  end if;
  if invitation.accepted_by is not null then
    raise exception 'This invitation was already accepted. Remove the family member instead.' using errcode='22023';
  end if;
  update public.household_invites set expires_at=least(expires_at,statement_timestamp()) where code=invite_code;
end $$;

create function relay_household_private.invite_member(member_email text, member_role text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare home uuid:=relay_household_private.lock_owned_household(); token uuid; cleaned_email text;
begin
  cleaned_email:=lower(btrim(coalesce(member_email,'')));
  if char_length(cleaned_email)>254 or cleaned_email !~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$' then
    raise exception 'Enter a valid email address.' using errcode='22023';
  end if;
  if member_role is null or member_role not in ('parent','caregiver') then
    raise exception 'Choose a valid family role.' using errcode='22023';
  end if;
  select i.code into token from public.household_invites i
    where i.household_id=home and i.email=cleaned_email and i.member_role=invite_member.member_role
      and i.accepted_by is null and i.expires_at>statement_timestamp()
    order by i.expires_at desc,i.code limit 1 for update;
  if token is not null then return token; end if;
  update public.household_invites i set expires_at=statement_timestamp()
    where i.household_id=home and i.email=cleaned_email and i.accepted_by is null
      and i.expires_at>statement_timestamp();
  insert into public.household_invites(household_id,email,created_by,member_role)
    values(home,cleaned_email,auth.uid(),invite_member.member_role) returning code into token;
  return token;
end $$;

create function relay_household_private.remove_member(member_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare home uuid;
  member public.household_members%rowtype; record public.parent_records%rowtype;
  family public.households%rowtype; stamp timestamptz:=clock_timestamp(); normalized jsonb; target_email text;
begin
  if member_user_id is null or member_user_id=auth.uid() then
    raise exception 'You cannot remove yourself or the family owner.' using errcode='42501';
  end if;
  if not relay_household_private.lock_auth_user(member_user_id) then
    raise exception 'This family member is no longer available. Refresh and try again.' using errcode='42501';
  end if;
  home:=relay_household_private.lock_owned_household();
  -- Expire pending codes before locking member/records, matching join's order.
  select u.email into target_email from auth.users u where u.id=member_user_id;
  update public.household_invites i set expires_at=least(i.expires_at,statement_timestamp())
    where i.household_id=home and i.accepted_by is null and lower(i.email)=lower(target_email);
  select * into member from public.household_members
    where user_id=member_user_id and household_id=home and is_active for update;
  if member.user_id is null then
    raise exception 'This member is no longer in your family. Refresh and try again.' using errcode='42501';
  end if;
  if member.role='owner' then
    raise exception 'The family owner cannot be removed.' using errcode='42501';
  end if;
  select * into family from public.households where id=home;
  select * into record from public.parent_records where user_id=member_user_id for update;
  if record.user_id is null then
    raise exception 'Their saved records are unavailable. Nothing was removed; contact support.' using errcode='42501';
  end if;
  normalized:=relay_household_private.normalize_care_children(record.payload,'{}'::jsonb,cardinality(family.child_names),true);
  normalized:=jsonb_set(normalized,'{childNames}',to_jsonb(family.child_names),true);
  insert into relay_household_private.record_archives(user_id,household_id,household_name,child_names,payload,revision,archived_at)
    values(member_user_id,home,family.name,family.child_names,normalized,record.revision,stamp);
  update public.household_members set household_id=null,is_active=false,deactivated_at=stamp where user_id=member_user_id;
end $$;

create function relay_household_private.list_record_archives()
returns table(id uuid,household_id uuid,household_name text,child_names text[],payload jsonb,revision bigint,archived_at timestamptz,is_current boolean)
language plpgsql stable security definer set search_path = '' as $$
declare request_user uuid:=relay_household_private.require_user();
begin
  return query select a.id,a.household_id,a.household_name,a.child_names,a.payload,a.revision,a.archived_at,
    exists(select 1 from public.household_members m where m.user_id=request_user and not m.is_active and m.deactivated_at=a.archived_at)
    from relay_household_private.record_archives a where a.user_id=request_user
    order by a.archived_at desc,a.id;
end $$;

-- These helpers are never executable by clients. A rejoin starts a clean
-- shared snapshot; the former scope remains only in the person's archive.
create function relay_household_private.attach_member(request_user uuid, home uuid, member_name text, member_role text, children text[]) returns void
language plpgsql security invoker set search_path = '' as $$
declare prior public.household_members%rowtype; empty_payload jsonb;
begin
  select * into prior from public.household_members where user_id=request_user for update;
  if prior.user_id is not null and prior.is_active then
    raise exception 'You already belong to a family.' using errcode='42501';
  end if;
  if prior.user_id is not null and not exists(select 1 from relay_household_private.record_archives a
    where a.user_id=request_user and a.archived_at=prior.deactivated_at) then
    raise exception 'Your previous family records need recovery before joining. Contact support.' using errcode='42501';
  end if;
  empty_payload:=jsonb_build_object('version',2,'alerts',false,'childNames',to_jsonb(children),'shifts','[]'::jsonb,'sessions','[]'::jsonb);
  insert into public.household_members(user_id,household_id,display_name,role,is_active,deactivated_at)
    values(request_user,home,btrim(member_name),member_role,true,null)
    on conflict(user_id) do update set household_id=excluded.household_id,display_name=excluded.display_name,
      role=excluded.role,joined_at=statement_timestamp(),is_active=true,deactivated_at=null;
  delete from relay_sync_private.mutation_receipts where owner_id=request_user;
  insert into public.parent_records(user_id,payload) values(request_user,empty_payload)
    on conflict(user_id) do update set payload=excluded.payload,revision=public.parent_records.revision+1,updated_at=statement_timestamp();
end $$;

create function relay_household_private.create_household(household_name text,member_name text,children text[],caregiver_total integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare request_user uuid:=relay_household_private.require_user(); home uuid; cleaned text[];
begin
  if not relay_household_private.lock_auth_user(request_user) then
    raise exception 'Sign in again before changing your family.' using errcode='28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('relay-household:' || request_user::text,0));
  if household_name is null or char_length(btrim(household_name)) not between 1 and 80
    or member_name is null or char_length(btrim(member_name)) not between 1 and 80
    or caregiver_total is null or caregiver_total not between 1 and 12 then
    raise exception 'Check the family details and try again.' using errcode='22023';
  end if;
  cleaned:=relay_household_private.clean_children(children);
  if exists(select 1 from public.household_members where user_id=request_user and is_active) then
    raise exception 'You already belong to a family.' using errcode='42501';
  end if;
  insert into public.households(name,child_one,child_two,child_names,caregiver_total)
    values(btrim(household_name),cleaned[1],coalesce(cleaned[2],'Baby 2'),cleaned,create_household.caregiver_total)
    returning id into home;
  perform relay_household_private.attach_member(request_user,home,member_name,'owner',cleaned);
  return home;
end $$;

create function relay_household_private.join_household(invite_code uuid,parent_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare request_user uuid:=relay_household_private.require_user(); home uuid; invitation public.household_invites%rowtype;
  children text[]; request_email text;
begin
  if not relay_household_private.lock_auth_user(request_user) then
    raise exception 'Sign in again before changing your family.' using errcode='28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('relay-household:' || request_user::text,0));
  if parent_name is null or char_length(btrim(parent_name)) not between 1 and 80 then
    raise exception 'Enter a name up to 80 characters.' using errcode='22023';
  end if;
  if exists(select 1 from public.household_members where user_id=request_user and is_active) then
    raise exception 'You already belong to a family.' using errcode='42501';
  end if;
  -- Read scope first, then lock household and invitation in administration order.
  select i.household_id into home from public.household_invites i where i.code=invite_code;
  perform 1 from public.households where id=home for update;
  select * into invitation from public.household_invites where code=invite_code for update;
  select lower(email) into request_email from auth.users where id=request_user;
  if invitation.code is null or invitation.household_id is distinct from home or invitation.accepted_by is not null
    or invitation.expires_at<=statement_timestamp() or invitation.email is distinct from request_email then
    raise exception 'This invitation is invalid, expired, or belongs to another email.' using errcode='42501';
  end if;
  if (select count(*) from public.household_members where household_id=home and is_active)>=12 then
    raise exception 'This family already has 12 members.' using errcode='22023';
  end if;
  select child_names into children from public.households where id=home;
  if children is null then raise exception 'This family is no longer available.' using errcode='42501'; end if;
  perform relay_household_private.attach_member(request_user,home,parent_name,invitation.member_role,children);
  update public.household_invites set accepted_by=request_user where code=invite_code;
  return home;
end $$;

create function relay_household_private.update_name(new_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare home uuid:=relay_household_private.lock_owned_household();
begin
  if new_name is null or char_length(btrim(new_name)) not between 1 and 80 then
    raise exception 'Enter a family name up to 80 characters.' using errcode='22023';
  end if;
  update public.households set name=btrim(new_name) where id=home;
end $$;

create function relay_household_private.save_legacy_records(expected_revision bigint,new_payload jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare request_user uuid:=relay_household_private.require_user(); home uuid; record public.parent_records%rowtype; child_count integer;
begin
  if not relay_household_private.lock_auth_user(request_user) then
    raise exception 'Sign in again before saving your records.' using errcode='28000';
  end if;
  select household_id into home from public.household_members where user_id=request_user and is_active for share;
  if home is null then
    raise exception 'Your family membership changed. Reconnect before saving.' using errcode='42501';
  end if;
  if exists(select 1 from relay_household_private.record_archives where user_id=request_user) then
    raise exception 'Update Relay before syncing after a family change. Your previous records are safe in Your saved time.' using errcode='42501';
  end if;
  if expected_revision is null or expected_revision<0 or jsonb_typeof(new_payload) is distinct from 'object'
    or jsonb_typeof(new_payload->'sessions') is distinct from 'array'
    or jsonb_typeof(new_payload->'shifts') is distinct from 'array'
    or octet_length(new_payload::text)>10000000 then
    raise exception 'Invalid saved records.' using errcode='22023';
  end if;
  select * into record from public.parent_records where user_id=request_user for update;
  if record.user_id is null or record.revision<>expected_revision then
    raise exception 'Records changed on another device. Refresh before trying again.' using errcode='40001';
  end if;
  select cardinality(child_names) into child_count from public.households where id=home;
  new_payload:=relay_household_private.normalize_care_children(new_payload,record.payload,child_count);
  update public.parent_records set payload=new_payload,revision=revision+1,updated_at=statement_timestamp()
    where user_id=request_user returning revision into expected_revision;
  return expected_revision;
end $$;

-- Exposed functions are invoker-only wrappers. Their private implementations
-- derive identity and permissions from the current live Auth session.
create or replace function public.relay_household() returns uuid
language sql stable security invoker set search_path='' as $$ select relay_household_private.active_household(); $$;
create or replace function public.relay_is_admin() returns boolean
language sql stable security invoker set search_path='' as $$ select relay_household_private.is_admin(); $$;
create function public.relay_update_household_children(children text[]) returns text[]
language sql security invoker set search_path='' as $$ select relay_household_private.update_children(children); $$;
create function public.relay_list_household_invites() returns table(code uuid,email text,member_role text,expires_at timestamptz)
language sql security invoker set search_path='' as $$ select * from relay_household_private.list_invites(); $$;
create function public.relay_revoke_household_invite(invite_code uuid) returns void
language sql security invoker set search_path='' as $$ select relay_household_private.revoke_invite(invite_code); $$;
create function public.relay_remove_household_member(member_user_id uuid) returns void
language sql security invoker set search_path='' as $$ select relay_household_private.remove_member(member_user_id); $$;
create function public.relay_list_personal_record_archives()
returns table(id uuid,household_id uuid,household_name text,child_names text[],payload jsonb,revision bigint,archived_at timestamptz,is_current boolean)
language sql stable security invoker set search_path='' as $$ select * from relay_household_private.list_record_archives(); $$;
create or replace function public.relay_create_household_v2(household_name text,member_name text,children text[],caregiver_total integer) returns uuid
language sql security invoker set search_path='' as $$ select relay_household_private.create_household(household_name,member_name,children,caregiver_total); $$;
create or replace function public.relay_create_household(household_name text,parent_name text,child_one text,child_two text) returns uuid
language sql security invoker set search_path='' as $$ select relay_household_private.create_household(household_name,parent_name,array[child_one,child_two],1); $$;
create or replace function public.relay_invite_member(member_email text,member_role text) returns uuid
language sql security invoker set search_path='' as $$ select relay_household_private.invite_member(member_email,member_role); $$;
create or replace function public.relay_invite_parent(parent_email text) returns uuid
language sql security invoker set search_path='' as $$ select relay_household_private.invite_member(parent_email,'parent'); $$;
create or replace function public.relay_join_household(invite_code uuid,parent_name text) returns uuid
language sql security invoker set search_path='' as $$ select relay_household_private.join_household(invite_code,parent_name); $$;
create or replace function public.relay_update_household_name(new_name text) returns void
language sql security invoker set search_path='' as $$ select relay_household_private.update_name(new_name); $$;
create or replace function public.relay_save_records(expected_revision bigint,new_payload jsonb) returns bigint
language sql security invoker set search_path='' as $$ select relay_household_private.save_legacy_records(expected_revision,new_payload); $$;

-- No raw private archive access and no arbitrary-identity internal helpers.
revoke all on all functions in schema relay_household_private from public,anon,authenticated,service_role;
grant execute on function relay_household_private.verified_user(),relay_household_private.active_household(),
  relay_household_private.is_admin(),relay_household_private.update_children(text[]),relay_household_private.list_invites(),
  relay_household_private.revoke_invite(uuid),relay_household_private.invite_member(text,text),relay_household_private.remove_member(uuid),
  relay_household_private.list_record_archives(),relay_household_private.create_household(text,text,text[],integer),
  relay_household_private.join_household(uuid,text),relay_household_private.update_name(text),
  relay_household_private.save_legacy_records(bigint,jsonb) to authenticated;
revoke all on function public.relay_household(),public.relay_is_admin(),public.relay_update_household_children(text[]),
  public.relay_list_household_invites(),public.relay_revoke_household_invite(uuid),public.relay_remove_household_member(uuid),
  public.relay_list_personal_record_archives(),public.relay_create_household_v2(text,text,text[],integer),
  public.relay_create_household(text,text,text,text),public.relay_invite_member(text,text),public.relay_invite_parent(text),
  public.relay_join_household(uuid,text),public.relay_update_household_name(text),public.relay_save_records(bigint,jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.relay_household(),public.relay_is_admin(),public.relay_update_household_children(text[]),
  public.relay_list_household_invites(),public.relay_revoke_household_invite(uuid),public.relay_remove_household_member(uuid),
  public.relay_list_personal_record_archives(),public.relay_create_household_v2(text,text,text[],integer),
  public.relay_create_household(text,text,text,text),public.relay_invite_member(text,text),public.relay_invite_parent(text),
  public.relay_join_household(uuid,text),public.relay_update_household_name(text),public.relay_save_records(bigint,jsonb)
  to authenticated;

drop policy household_read on public.households;
create policy household_read on public.households for select to authenticated
  using(id=(select public.relay_household()) or (select public.relay_is_admin()));
drop policy members_read on public.household_members;
create policy members_read on public.household_members for select to authenticated
  using(user_id=(select relay_household_private.verified_user())
    or (is_active and household_id=(select public.relay_household())) or (select public.relay_is_admin()));
drop policy records_read on public.parent_records;
create policy records_read on public.parent_records for select to authenticated
  using(user_id=(select relay_household_private.verified_user()) or user_id in (
    select m.user_id from public.household_members m
      where m.is_active and m.household_id=(select public.relay_household())
  ) or (select public.relay_is_admin()));

-- Keep expected-household mutation receipts and hash the original request;
-- normalize only the accepted payload so legacy retries remain idempotent.
create or replace function relay_sync_private.sync_records(
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
  current_child_count integer;
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

  -- Match Auth deletion's Auth-user -> member -> record lock order.
  if not relay_household_private.lock_auth_user(request_user) then
    raise exception 'Sign in again before syncing your saved changes.' using errcode='28000';
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
    where m.user_id = request_user and m.is_active
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
  select cardinality(h.child_names) into current_child_count
    from public.households h where h.id=current_household;
  new_payload:=relay_household_private.normalize_care_children(
    new_payload,current_record.payload,current_child_count
  );

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

commit;
