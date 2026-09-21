begin;
create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 80),
  child_one text not null check (length(child_one) between 1 and 40),
  child_two text not null check (length(child_two) between 1 and 40),
  created_at timestamptz not null default now()
);
create table public.household_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.households(id),
  display_name text not null check (length(display_name) between 1 and 80),
  role text not null check (role in ('owner','parent')),
  joined_at timestamptz not null default now()
);
create index on public.household_members(household_id);
-- Each parent owns a versioned snapshot. Partners can read it but cannot
-- overwrite one another's timers. Revisions protect multiple devices.
create table public.parent_records (
  user_id uuid primary key references public.household_members(user_id) on delete cascade,
  payload jsonb not null default '{"version":2,"alerts":false,"shifts":[],"sessions":[]}'::jsonb,
  revision bigint not null default 0,
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(payload) = 'object'),
  check (jsonb_typeof(payload->'shifts') = 'array'),
  check (jsonb_typeof(payload->'sessions') = 'array')
);
create table public.household_invites (
  code uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  email text not null,
  created_by uuid not null references auth.users(id),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_by uuid references auth.users(id)
);
create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.parent_records enable row level security;
alter table public.household_invites enable row level security;
alter table public.platform_admins enable row level security;

create function public.relay_household() returns uuid
language sql stable security definer set search_path = '' as $$
  select household_id from public.household_members where user_id = auth.uid();
$$;
create function public.relay_is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.platform_admins where user_id = auth.uid());
$$;
create policy household_read on public.households for select to authenticated
  using (id = (select public.relay_household()) or (select public.relay_is_admin()));
create policy members_read on public.household_members for select to authenticated
  using (household_id = (select public.relay_household()) or (select public.relay_is_admin()));
create policy records_read on public.parent_records for select to authenticated using (
  user_id in (select m.user_id from public.household_members m where m.household_id = (select public.relay_household()))
  or (select public.relay_is_admin())
);
-- No client write policies: validated RPCs are the only write entrypoints.
revoke all on public.households, public.household_members, public.parent_records,
  public.household_invites, public.platform_admins from anon, authenticated;
grant select on public.households, public.household_members, public.parent_records to authenticated;

create function public.relay_create_household(household_name text, parent_name text, child_one text, child_two text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare h uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists(select 1 from public.household_members where user_id = auth.uid()) then
    raise exception 'You already belong to a household';
  end if;
  insert into public.households(name, child_one, child_two)
    values(trim(household_name), trim(child_one), trim(child_two)) returning id into h;
  insert into public.household_members values(auth.uid(), h, trim(parent_name), 'owner', now());
  insert into public.parent_records(user_id) values(auth.uid());
  return h;
end $$;

create function public.relay_invite_parent(parent_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare h uuid; token uuid;
begin
  select household_id into h from public.household_members where user_id = auth.uid() and role = 'owner';
  if h is null then raise exception 'Only the household owner can create invitations'; end if;
  if length(parent_email) > 254 or parent_email not like '%@%.%' then raise exception 'Enter a valid email'; end if;
  insert into public.household_invites(household_id,email,created_by)
    values(h,lower(trim(parent_email)),auth.uid()) returning code into token;
  return token;
end $$;

create function public.relay_join_household(invite_code uuid, parent_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare invite public.household_invites;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into invite from public.household_invites where code = invite_code for update;
  if invite.code is null or invite.accepted_by is not null or invite.expires_at <= now()
    or invite.email <> lower(coalesce(auth.jwt()->>'email','')) then
    raise exception 'This invitation is invalid, expired, or belongs to another email';
  end if;
  insert into public.household_members values(auth.uid(), invite.household_id, trim(parent_name), 'parent', now());
  insert into public.parent_records(user_id) values(auth.uid());
  update public.household_invites set accepted_by = auth.uid() where code = invite_code;
  return invite.household_id;
end $$;

create function public.relay_save_records(expected_revision bigint, new_payload jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare updated_revision bigint;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if jsonb_typeof(new_payload) <> 'object'
    or jsonb_typeof(new_payload->'sessions') is distinct from 'array'
    or jsonb_typeof(new_payload->'shifts') is distinct from 'array'
    or octet_length(new_payload::text) > 10000000 then raise exception 'Invalid records'; end if;
  update public.parent_records set payload = new_payload, revision = revision + 1, updated_at = now()
    where user_id = auth.uid() and revision = expected_revision returning revision into updated_revision;
  if updated_revision is null then raise exception 'Records changed on another device. Refresh before trying again.' using errcode = '40001'; end if;
  return updated_revision;
end $$;

revoke all on function public.relay_household(), public.relay_is_admin(),
 public.relay_create_household(text,text,text,text), public.relay_invite_parent(text),
 public.relay_join_household(uuid,text), public.relay_save_records(bigint,jsonb) from public, anon;
grant execute on function public.relay_household(), public.relay_is_admin(),
 public.relay_create_household(text,text,text,text), public.relay_invite_parent(text),
 public.relay_join_household(uuid,text), public.relay_save_records(bigint,jsonb) to authenticated;
commit;
