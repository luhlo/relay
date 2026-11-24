begin;

-- Client roles cannot access these tables, even when signed in. The Edge
-- handler is the sole public surface and independently authorizes all reads.
create table public.relay_support_admins (
  email text primary key check (email = lower(email) and char_length(email) <= 254)
);

create table public.relay_support_feedback (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('problem', 'idea', 'question')),
  message text not null check (char_length(btrim(message)) between 10 and 2000),
  reply_email text check (
    reply_email is null or (
      char_length(reply_email) <= 254 and
      reply_email ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
    )
  ),
  app_version text not null check (app_version ~ '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\+[0-9]{1,9})?$'),
  platform text not null check (platform in ('web', 'android', 'ios', 'linux', 'macos', 'windows', 'fuchsia', 'unknown')),
  created_at timestamptz not null default statement_timestamp()
);

create table public.relay_technical_reports (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in ('flutter_error', 'unhandled_error', 'slow_operation', 'slow_frame')),
  code text not null check (code in (
    'FlutterError', 'StateError', 'TypeError', 'RangeError', 'ArgumentError',
    'AssertionError', 'FormatException', 'TimeoutException', 'PlatformException',
    'MissingPluginException', 'PostgrestException', 'AuthException',
    'SocketException', 'Exception', 'UnknownError', 'SlowOperation', 'SlowFrame'
  )),
  operation text check (operation in ('load_records', 'save_records', 'launch', 'render')),
  duration_ms integer check (duration_ms between 0 and 86400000),
  app_version text not null check (app_version ~ '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\+[0-9]{1,9})?$'),
  platform text not null check (platform in ('web', 'android', 'ios', 'linux', 'macos', 'windows', 'fuchsia', 'unknown')),
  fingerprint text not null check (fingerprint ~ '^[a-f0-9]{8,64}$'),
  frames jsonb not null default '[]'::jsonb check (jsonb_typeof(frames) = 'array' and jsonb_array_length(frames) <= 10),
  created_at timestamptz not null default statement_timestamp(),
  check (event_type <> 'slow_operation' or (code = 'SlowOperation' and operation is not null and duration_ms is not null)),
  check (event_type <> 'slow_frame' or (code = 'SlowFrame' and operation = 'render' and duration_ms is not null))
);

-- No raw IP is retained. The bucket key contains a server-secret HMAC plus a
-- short time window; these rows are purged automatically after expiry.
create table public.relay_support_rate_buckets (
  bucket_key text primary key check (char_length(bucket_key) <= 100),
  requests integer not null check (requests between 1 and 2000),
  expires_at timestamptz not null
);

create index relay_support_feedback_created_at on public.relay_support_feedback (created_at desc);
create index relay_technical_reports_created_at on public.relay_technical_reports (created_at desc);
create index relay_support_rate_buckets_expires_at on public.relay_support_rate_buckets (expires_at);

alter table public.relay_support_admins enable row level security;
alter table public.relay_support_feedback enable row level security;
alter table public.relay_technical_reports enable row level security;
alter table public.relay_support_rate_buckets enable row level security;

revoke all on public.relay_support_admins, public.relay_support_feedback,
  public.relay_technical_reports, public.relay_support_rate_buckets
  from public, anon, authenticated;
grant select, insert, update, delete on public.relay_support_admins,
  public.relay_support_feedback, public.relay_technical_reports,
  public.relay_support_rate_buckets to service_role;

insert into public.relay_support_admins(email) values ('luhlostudios@gmail.com');

create function public.relay_support_take_rate(request_bucket text, request_kind text)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare
  stamp timestamptz := statement_timestamp();
  hourly_key text;
  daily_key text;
  hourly_count integer;
  daily_count integer;
  hourly_limit integer;
begin
  if request_bucket is null or request_bucket !~ '^[a-f0-9]{64}$'
    or request_kind is null or request_kind not in ('feedback', 'diagnostic') then
    raise exception 'Invalid report limiter request.' using errcode = '22023';
  end if;
  hourly_limit := case when request_kind = 'feedback' then 5 else 30 end;
  hourly_key := request_kind || ':' || request_bucket || ':' || to_char(stamp at time zone 'UTC', 'YYYYMMDDHH24');
  daily_key := 'global:' || to_char(stamp at time zone 'UTC', 'YYYYMMDD');

  -- One transaction lock makes the per-source and global checks atomic. A
  -- rejected request consumes neither quota and cannot race parallel inserts.
  perform pg_catalog.pg_advisory_xact_lock(783166621, 1);
  select requests into hourly_count from public.relay_support_rate_buckets where bucket_key = hourly_key;
  select requests into daily_count from public.relay_support_rate_buckets where bucket_key = daily_key;
  if coalesce(hourly_count, 0) >= hourly_limit or coalesce(daily_count, 0) >= 2000 then
    return false;
  end if;
  insert into public.relay_support_rate_buckets(bucket_key, requests, expires_at)
    values (hourly_key, 1, date_trunc('hour', stamp, 'UTC') + interval '1 hour')
    on conflict (bucket_key) do update set requests = public.relay_support_rate_buckets.requests + 1;
  insert into public.relay_support_rate_buckets(bucket_key, requests, expires_at)
    values (daily_key, 1, date_trunc('day', stamp, 'UTC') + interval '1 day')
    on conflict (bucket_key) do update set requests = public.relay_support_rate_buckets.requests + 1;
  return true;
end;
$$;
revoke all on function public.relay_support_take_rate(text, text) from public, anon, authenticated;
grant execute on function public.relay_support_take_rate(text, text) to service_role;

create function public.relay_support_cleanup() returns void
language plpgsql security invoker set search_path = '' as $$
begin
  delete from public.relay_technical_reports where created_at < statement_timestamp() - interval '90 days';
  delete from public.relay_support_feedback where created_at < statement_timestamp() - interval '180 days';
  delete from public.relay_support_rate_buckets where expires_at < statement_timestamp() - interval '1 day';
end;
$$;
revoke all on function public.relay_support_cleanup() from public, anon, authenticated;
grant execute on function public.relay_support_cleanup() to service_role;

-- Retention runs on the database directly; no network secret or HTTP call is
-- stored in cron. Existing household/session tables are never touched.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('relay-support-retention', '13 4 * * *', 'select public.relay_support_cleanup();');

commit;
