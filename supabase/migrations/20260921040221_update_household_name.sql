create or replace function public.relay_update_household_name(new_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  household_to_update uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in first';
  end if;

  if length(trim(new_name)) not between 1 and 80 then
    raise exception 'Enter a family name up to 80 characters';
  end if;

  select household_id
  into household_to_update
  from public.household_members
  where user_id = auth.uid()
    and role = 'owner';

  if household_to_update is null then
    raise exception 'Only the family owner can change the family name';
  end if;

  update public.households
  set name = trim(new_name)
  where id = household_to_update;
end;
$$;

revoke all on function public.relay_update_household_name(text)
from public, anon, authenticated;

grant execute on function public.relay_update_household_name(text)
to authenticated;
