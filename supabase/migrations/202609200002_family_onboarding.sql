begin;

alter table public.households
  add column if not exists child_names text[],
  add column if not exists caregiver_total integer not null default 1;

update public.households
set child_names = array[child_one, child_two]
where child_names is null;

alter table public.households
  alter column child_names set not null;

alter table public.households
  add constraint households_child_names_check
    check (cardinality(child_names) between 1 and 8),
  add constraint households_caregiver_total_check
    check (caregiver_total between 1 and 12);

alter table public.household_members
  drop constraint if exists household_members_role_check;
alter table public.household_members
  add constraint household_members_role_check
    check (role in ('owner', 'parent', 'caregiver'));

alter table public.household_invites
  add column if not exists member_role text not null default 'parent';
alter table public.household_invites
  add constraint household_invites_member_role_check
    check (member_role in ('parent', 'caregiver'));

create or replace function public.relay_create_household_v2(
  household_name text,
  member_name text,
  children text[],
  caregiver_total integer
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare h uuid; cleaned text[];
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists(select 1 from public.household_members where user_id = auth.uid()) then
    raise exception 'You already belong to a household';
  end if;
  if length(trim(household_name)) not between 1 and 80
    or length(trim(member_name)) not between 1 and 80
    or cardinality(children) not between 1 and 8
    or caregiver_total not between 1 and 12 then
    raise exception 'Check the household details and try again';
  end if;
  select array_agg(
    case when trim(value) = '' then 'Baby ' || position else trim(value) end
    order by position
  ) into cleaned
  from unnest(children) with ordinality as names(value, position)
  where length(trim(value)) <= 40;
  if cardinality(cleaned) is distinct from cardinality(children) then
    raise exception 'Child names must be 40 characters or fewer';
  end if;
  insert into public.households(name, child_one, child_two, child_names, caregiver_total)
    values(
      trim(household_name),
      cleaned[1],
      coalesce(cleaned[2], 'Baby 2'),
      cleaned,
      caregiver_total
    ) returning id into h;
  insert into public.household_members values(auth.uid(), h, trim(member_name), 'owner', now());
  insert into public.parent_records(user_id) values(auth.uid());
  return h;
end $$;

create or replace function public.relay_invite_member(member_email text, member_role text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare h uuid; token uuid;
begin
  select household_id into h from public.household_members
    where user_id = auth.uid() and role = 'owner';
  if h is null then raise exception 'Only the household owner can create invitations'; end if;
  if length(member_email) > 254 or lower(trim(member_email)) not like '%@%.%' then
    raise exception 'Enter a valid email';
  end if;
  if member_role not in ('parent', 'caregiver') then raise exception 'Choose a valid role'; end if;
  insert into public.household_invites(household_id, email, created_by, member_role)
    values(h, lower(trim(member_email)), auth.uid(), member_role)
    returning code into token;
  return token;
end $$;

create or replace function public.relay_join_household(invite_code uuid, parent_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare invite public.household_invites;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into invite from public.household_invites where code = invite_code for update;
  if invite.code is null or invite.accepted_by is not null or invite.expires_at <= now()
    or invite.email <> lower(coalesce(auth.jwt()->>'email','')) then
    raise exception 'This invitation is invalid, expired, or belongs to another email';
  end if;
  insert into public.household_members
    values(auth.uid(), invite.household_id, trim(parent_name), invite.member_role, now());
  insert into public.parent_records(user_id) values(auth.uid());
  update public.household_invites set accepted_by = auth.uid() where code = invite_code;
  return invite.household_id;
end $$;

revoke all on function public.relay_create_household_v2(text,text,text[],integer),
  public.relay_invite_member(text,text) from public, anon;
grant execute on function public.relay_create_household_v2(text,text,text[],integer),
  public.relay_invite_member(text,text) to authenticated;

commit;
