-- Phase 1 (additive): name ownership + secret-checked RPCs. Old clients keep working.
create table if not exists public.yzy_names (
  username_key text primary key,
  display_name text not null,
  secret_hash  text not null,
  created_at   timestamptz not null default now()
);
alter table public.yzy_names enable row level security;
revoke all on public.yzy_names from anon, authenticated;

-- Case/punctuation-insensitive key: "Big.Player", "big player", "BIGPLAYER" are one name.
create or replace function public.yzy_name_key(p text) returns text
language sql immutable set search_path = public as $$
  select case when length(regexp_replace(lower(btrim(coalesce(p,''))), '[^a-z0-9]', '', 'g')) >= 2
    then regexp_replace(lower(btrim(p)), '[^a-z0-9]', '', 'g')
    else lower(regexp_replace(btrim(coalesce(p,'')), '\s+', ' ', 'g')) end $$;

-- Does any existing (pre-claim) data use this name key?
create or replace function public.yzy__has_data(k text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from yzy_leaderboard where yzy_name_key(username) = k)
      or exists(select 1 from yzy_saves where yzy_name_key(username) = k)
      or exists(select 1 from yzy_weekly where yzy_name_key(username) = k) $$;

-- 'ok' | 'taken' | 'bad' | 'free' (only when p_claim = false). Trust-on-first-use claim.
create or replace function public.yzy__auth(p_username text, p_secret text, p_claim boolean default true) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare k text; h text; r public.yzy_names%rowtype;
begin
  if p_username is null or length(btrim(p_username)) < 2 or length(p_username) > 24 then return 'bad'; end if;
  if p_secret is null or p_secret !~ '^[0-9a-f]{64}$' then return 'bad'; end if;
  k := public.yzy_name_key(p_username);
  h := encode(extensions.digest(p_secret, 'sha256'), 'hex');
  select * into r from public.yzy_names where username_key = k;
  if found then return case when r.secret_hash = h then 'ok' else 'taken' end; end if;
  if not p_claim then return 'free'; end if;
  insert into public.yzy_names(username_key, display_name, secret_hash)
    values (k, upper(btrim(p_username)), h) on conflict do nothing;
  select * into r from public.yzy_names where username_key = k;
  return case when r.secret_hash = h then 'ok' else 'taken' end;
end $$;

create or replace function public.yzy_claim_name(p_username text, p_secret text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin return json_build_object('ok', a = 'ok', 'reason', a); end $$;

-- status: 'mine' | 'free' | 'taken' (claimed by another key, or existing unclaimed player) | 'bad'
create or replace function public.yzy_name_status(p_username text, p_secret text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare k text; r public.yzy_names%rowtype;
begin
  if p_username is null or length(btrim(p_username)) < 2 or length(p_username) > 24 then return json_build_object('status','bad'); end if;
  k := public.yzy_name_key(p_username);
  select * into r from public.yzy_names where username_key = k;
  if found then
    return json_build_object('status', case when p_secret ~ '^[0-9a-f]{64}$'
      and r.secret_hash = encode(extensions.digest(p_secret,'sha256'),'hex') then 'mine' else 'taken' end);
  end if;
  return json_build_object('status', case when public.yzy__has_data(k) then 'taken' else 'free' end);
end $$;

create or replace function public.yzy_save_put(p_username text, p_secret text, p_save_data text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if p_save_data is null or length(p_save_data) > 200000 then return json_build_object('ok', false, 'reason', 'size'); end if;
  insert into public.yzy_saves(username, save_data, saved_at) values (upper(btrim(p_username)), p_save_data, now())
    on conflict (username) do update set save_data = excluded.save_data, saved_at = excluded.saved_at;
  return json_build_object('ok', true);
end $$;

create or replace function public.yzy_save_get(p_username text, p_secret text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := public.yzy__auth(p_username, p_secret, true); s public.yzy_saves%rowtype;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  select * into s from public.yzy_saves where username = upper(btrim(p_username));
  if not found then return json_build_object('ok', true, 'save_data', null); end if;
  return json_build_object('ok', true, 'save_data', s.save_data, 'saved_at', s.saved_at);
end $$;

-- Same caps as the old RLS policies / table CHECK (50T bars, 50M clicks, >1T needs 5000 clicks, <=2B per click).
create or replace function public.yzy_lb_submit(p_username text, p_secret text, p_total_bars bigint, p_total_clicks bigint,
  p_era text default null, p_twitter text default null) returns json
language plpgsql security definer set search_path = public as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if p_total_bars is null or p_total_clicks is null or p_total_bars < 0 or p_total_clicks < 0
     or p_total_bars > 50000000000000 or p_total_clicks > 50000000
     or (p_total_bars > 1000000000000 and p_total_clicks < 5000)
     or (p_total_clicks <> 0 and p_total_bars::numeric / p_total_clicks > 2000000000) then
    return json_build_object('ok', false, 'reason', 'range');
  end if;
  insert into public.yzy_leaderboard(username, total_bars, total_clicks, era, twitter_handle, submitted_at)
    values (upper(btrim(p_username)), p_total_bars, p_total_clicks, left(p_era, 64), left(p_twitter, 15), now())
    on conflict (username) do update set total_bars = excluded.total_bars, total_clicks = excluded.total_clicks,
      era = excluded.era, twitter_handle = excluded.twitter_handle, submitted_at = excluded.submitted_at;
  return json_build_object('ok', true);
end $$;

-- Wraps the existing weekly logic unchanged.
create or replace function public.yzy_weekly_submit_v2(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric,
  p_era text default null, p_twitter text default null) returns json
language plpgsql security definer set search_path = public as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  return public.yzy_weekly_submit(upper(btrim(p_username)), p_total_bars, p_total_clicks, p_era, p_twitter);
end $$;

-- Move a name (claim + cloud save + leaderboard + weekly rows) to a new one.
create or replace function public.yzy_rename(p_old text, p_new text, p_secret text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a text; ko text; kn text; o text; n text; h text; r public.yzy_names%rowtype;
begin
  if p_new is null or length(btrim(p_new)) < 2 or length(p_new) > 24 or p_secret !~ '^[0-9a-f]{64}$' then
    return json_build_object('ok', false, 'reason', 'bad'); end if;
  ko := public.yzy_name_key(p_old); kn := public.yzy_name_key(p_new);
  o := upper(btrim(coalesce(p_old,''))); n := upper(btrim(p_new));
  h := encode(extensions.digest(p_secret,'sha256'),'hex');
  a := public.yzy__auth(p_old, p_secret, false);
  if kn <> ko or a <> 'ok' then
    select * into r from public.yzy_names where username_key = kn;
    if found and r.secret_hash <> h then return json_build_object('ok', false, 'reason', 'taken'); end if;
    if not found and public.yzy__has_data(kn) then return json_build_object('ok', false, 'reason', 'taken'); end if;
  end if;
  if a <> 'ok' then
    -- not the owner of the old name: just claim the new one, move nothing
    return json_build_object('ok', public.yzy__auth(p_new, p_secret, true) = 'ok', 'moved', false);
  end if;
  if kn <> ko then
    insert into public.yzy_names(username_key, display_name, secret_hash) values (kn, n, h)
      on conflict (username_key) do update set display_name = excluded.display_name;
    delete from public.yzy_names where username_key = ko;
  else
    update public.yzy_names set display_name = n where username_key = ko;
  end if;
  if n <> o then
    delete from public.yzy_saves where username = n;
    update public.yzy_saves set username = n where username = o;
    delete from public.yzy_leaderboard where username = n;
    update public.yzy_leaderboard set username = n where username = o;
    delete from public.yzy_weekly w where w.username = n and exists(select 1 from public.yzy_weekly x where x.username = o and x.week_start = w.week_start);
    update public.yzy_weekly set username = n where username = o;
  end if;
  return json_build_object('ok', true, 'moved', true);
end $$;

-- Reset: remove this player's cloud save + all-time row. Keeps the name claim unless p_release.
create or replace function public.yzy_delete(p_username text, p_secret text, p_release boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text := upper(btrim(coalesce(p_username,'')));
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  delete from public.yzy_saves where username = u;
  delete from public.yzy_leaderboard where username = u;
  if p_release then delete from public.yzy_names where username_key = public.yzy_name_key(p_username); end if;
  return json_build_object('ok', true);
end $$;

revoke all on function public.yzy__auth(text, text, boolean) from public, anon, authenticated;
revoke all on function public.yzy__has_data(text) from public, anon, authenticated;
grant execute on function public.yzy_claim_name(text, text), public.yzy_name_status(text, text),
  public.yzy_save_put(text, text, text), public.yzy_save_get(text, text),
  public.yzy_lb_submit(text, text, bigint, bigint, text, text),
  public.yzy_weekly_submit_v2(text, text, numeric, numeric, text, text),
  public.yzy_rename(text, text, text), public.yzy_delete(text, text, boolean) to anon, authenticated;
