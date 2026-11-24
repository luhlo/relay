-- Synthetic report/limiter rows only. Every change, including quota counters,
-- is rolled back; no family, Auth, or timer records are accessed.
begin;

do $$
declare
  table_name text;
  client_role text;
  privilege_name text;
begin
  foreach table_name in array array['relay_support_admins', 'relay_support_feedback', 'relay_technical_reports', 'relay_support_rate_buckets'] loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = table_name and c.relrowsecurity
    ) then
      raise exception 'Support table missing RLS: %', table_name;
    end if;
    foreach client_role in array array['anon', 'authenticated'] loop
      foreach privilege_name in array array['select', 'insert', 'update', 'delete'] loop
        if has_table_privilege(client_role, 'public.' || table_name, privilege_name) then
          raise exception 'Support table accessible to client: %, %', table_name, client_role;
        end if;
      end loop;
    end loop;
  end loop;
  if has_function_privilege('anon', 'public.relay_support_take_rate(text,text)', 'execute')
    or has_function_privilege('authenticated', 'public.relay_support_take_rate(text,text)', 'execute')
    or has_function_privilege('anon', 'public.relay_support_cleanup()', 'execute')
    or has_function_privilege('authenticated', 'public.relay_support_cleanup()', 'execute') then
    raise exception 'Support server RPC exposed to clients';
  end if;
  if not has_function_privilege('service_role', 'public.relay_support_take_rate(text,text)', 'execute')
    or not has_function_privilege('service_role', 'public.relay_support_cleanup()', 'execute') then
    raise exception 'Support server RPC not usable by service role';
  end if;
end;
$$;

set local role service_role;
do $$
declare
  bucket text := md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text);
  global_key text := 'global:' || to_char(statement_timestamp() at time zone 'UTC', 'YYYYMMDD');
  feedback_id uuid := gen_random_uuid();
  diagnostic_id uuid := gen_random_uuid();
  old_feedback_id uuid := gen_random_uuid();
  old_diagnostic_id uuid := gen_random_uuid();
  i integer;
begin
  -- Exercise the boundaries in one rollback transaction. Reset the shared
  -- fixture counter temporarily so prior production traffic cannot skew it.
  perform pg_catalog.pg_advisory_xact_lock(783166621, 1);
  insert into public.relay_support_rate_buckets(bucket_key,requests,expires_at)
    values(global_key,1,statement_timestamp()+interval '1 day')
    on conflict(bucket_key) do update set requests = 1;
  for i in 1..5 loop
    if not public.relay_support_take_rate(bucket, 'feedback') then
      raise exception 'Feedback accepted quota rejected early';
    end if;
  end loop;
  if public.relay_support_take_rate(bucket, 'feedback') then
    raise exception 'Feedback hourly limit exceeded';
  end if;
  for i in 1..30 loop
    if not public.relay_support_take_rate(bucket, 'diagnostic') then
      raise exception 'Diagnostic accepted quota rejected early';
    end if;
  end loop;
  if public.relay_support_take_rate(bucket, 'diagnostic') then
    raise exception 'Diagnostic hourly limit exceeded';
  end if;
  update public.relay_support_rate_buckets set requests = 1999 where bucket_key = global_key;
  bucket := md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text);
  if not public.relay_support_take_rate(bucket, 'feedback')
    or public.relay_support_take_rate(bucket, 'feedback') then
    raise exception 'Global daily report quota not enforced';
  end if;

  insert into public.relay_support_feedback(id,category,message,app_version,platform)
    values(feedback_id,'idea','Synthetic support fixture only.','1.17.0+22','android');
  insert into public.relay_technical_reports(id,event_type,code,app_version,platform,fingerprint,frames)
    values(diagnostic_id,'flutter_error','FlutterError','1.17.0+22','web','deadbeef','["package:relay/main.dart:1:1"]');
  insert into public.relay_support_feedback(id,category,message,app_version,platform,created_at)
    values(old_feedback_id,'idea','Synthetic expired fixture only.','1.17.0+22','android',statement_timestamp()-interval '181 days');
  insert into public.relay_technical_reports(id,event_type,code,app_version,platform,fingerprint,created_at)
    values(old_diagnostic_id,'unhandled_error','StateError','1.17.0+22','android','deadbeef',statement_timestamp()-interval '91 days');
  perform public.relay_support_cleanup();
  if not exists(select 1 from public.relay_support_feedback where id = feedback_id)
    or not exists(select 1 from public.relay_technical_reports where id = diagnostic_id)
    or exists(select 1 from public.relay_support_feedback where id = old_feedback_id)
    or exists(select 1 from public.relay_technical_reports where id = old_diagnostic_id) then
    raise exception 'Report retention boundaries failed';
  end if;
end;
$$;
reset role;

select 'Support report privileges, quotas and retention checks passed' as result;
rollback;
