begin;

-- This schema is not exposed through the Data API. No client can invoke these
-- privileged helpers. Account deletion itself remains in Supabase Auth Admin.
create schema if not exists relay_private;
revoke all on schema relay_private from public, anon, authenticated;
grant usage on schema relay_private to service_role;

create function relay_private.account_deletion_session_active(
  request_user uuid, request_session uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select request_user is not null and request_session is not null and exists (
    select 1 from auth.sessions s
    where s.id = request_session and s.user_id = request_user
      and (s.not_after is null or s.not_after > now())
  );
$$;
revoke all on function relay_private.account_deletion_session_active(uuid,uuid)
  from public, anon, authenticated;
grant execute on function relay_private.account_deletion_session_active(uuid,uuid)
  to service_role;

-- Only the server service role can call this invoker wrapper. Its arguments
-- come from a token validated against Auth, never from the request body.
create function public.relay_account_deletion_session_active(
  request_user uuid, request_session uuid
) returns boolean
language sql stable security invoker set search_path = '' as $$
  select relay_private.account_deletion_session_active(request_user, request_session);
$$;
revoke all on function public.relay_account_deletion_session_active(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.relay_account_deletion_session_active(uuid,uuid)
  to service_role;

create function relay_private.cleanup_deleted_account() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  household uuid;
  replacement uuid;
begin
  select m.household_id into household
    from public.household_members m where m.user_id = old.id;

  -- Serialize simultaneous departures from a household. Any failed cleanup
  -- rolls back the Auth deletion and its cascades as one transaction.
  if household is not null then
    perform 1 from public.households h where h.id = household for update;
  end if;

  delete from public.household_invites i
    where i.created_by = old.id or i.accepted_by = old.id
      or (old.email is not null and lower(i.email) = lower(old.email));
  -- parent_records is ON DELETE CASCADE from this membership.
  delete from public.household_members m where m.user_id = old.id;

  if household is not null then
    if not exists (
      select 1 from public.household_members m where m.household_id = household
    ) then
      delete from public.household_invites i where i.household_id = household;
      delete from public.households h where h.id = household;
    elsif not exists (
      select 1 from public.household_members m
        where m.household_id = household and m.role = 'owner'
    ) then
      select m.user_id into replacement from public.household_members m
        where m.household_id = household
        order by m.joined_at, m.user_id limit 1;
      update public.household_members set role = 'owner'
        where user_id = replacement;
    end if;
  end if;
  return old;
end;
$$;
revoke all on function relay_private.cleanup_deleted_account()
  from public, anon, authenticated, service_role;

create trigger relay_cleanup_deleted_account
  before delete on auth.users
  for each row execute function relay_private.cleanup_deleted_account();

commit;
