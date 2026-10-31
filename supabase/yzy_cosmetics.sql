-- Cosmetics shop: ¥ Board name effects + profile card frames, bought with YzY Tokens.
-- Budget is derived server-side: earned = yzy_leaderboard.prestige (1 YzY Token per prestige level) (never decreases,
-- +3 max per submit), balance = earned − sum(price of owned items). Plaques are never spent.
-- NOT YET APPLIED — apply after approval.
begin;

create table if not exists public.yzy_cosmetics_catalog (
  item_id text primary key,
  kind    text not null check (kind in ('fx','frame')),
  price   int  not null check (price >= 0)
);
alter table public.yzy_cosmetics_catalog enable row level security;
drop policy if exists yzy_cosmetics_catalog_read on public.yzy_cosmetics_catalog;
create policy yzy_cosmetics_catalog_read on public.yzy_cosmetics_catalog for select to anon, authenticated using (true);
grant select on public.yzy_cosmetics_catalog to anon, authenticated;

insert into public.yzy_cosmetics_catalog(item_id, kind, price) values
  ('fx_cream','fx',0), ('fx_gold','fx',1), ('fx_silver','fx',1), ('fx_red','fx',2),
  ('fx_sunset','fx',3), ('fx_glow','fx',4), ('fx_shimmer','fx',6), ('fx_glitch','fx',8), ('fx_rainbow','fx',12),
  ('fr_concrete','frame',0), ('fr_gold','frame',2), ('fr_808','frame',4), ('fr_mbdtf','frame',6),
  ('fr_yeezus','frame',9), ('fr_trillion','frame',15)
on conflict (item_id) do update set kind = excluded.kind, price = excluded.price;

create table if not exists public.yzy_cosmetics_owned (
  username text not null,
  item_id  text not null references public.yzy_cosmetics_catalog(item_id),
  price    int  not null,
  bought_at timestamptz not null default now(),
  primary key (username, item_id)
);
alter table public.yzy_cosmetics_owned enable row level security;   -- no policies: RPC-only
revoke all on public.yzy_cosmetics_owned from anon, authenticated;

alter table public.yzy_leaderboard add column if not exists name_fx text;
alter table public.yzy_leaderboard add column if not exists frame text;
grant select (name_fx, frame) on public.yzy_leaderboard to anon, authenticated;

-- Deleting a board row (yzy_delete / reset) also clears purchases, since prestige (the budget) is gone too.
create or replace function public.yzy__cosmetics_on_lb_delete() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin delete from public.yzy_cosmetics_owned where username = old.username; return old; end $$;
drop trigger if exists yzy_cosmetics_on_lb_delete on public.yzy_leaderboard;
create trigger yzy_cosmetics_on_lb_delete after delete on public.yzy_leaderboard
  for each row execute function public.yzy__cosmetics_on_lb_delete();

create or replace function public.yzy__cosmetics_state(u text) returns json
language sql stable security definer set search_path to 'public' as $$
  select json_build_object('ok', true,
    'earned', coalesce(l.prestige, 0),
    'spent',  coalesce((select sum(price) from public.yzy_cosmetics_owned o where o.username = u), 0),
    'balance', coalesce(l.prestige, 0) - coalesce((select sum(price) from public.yzy_cosmetics_owned o where o.username = u), 0),
    'owned',  coalesce((select json_agg(item_id order by item_id) from public.yzy_cosmetics_owned o where o.username = u), '[]'::json),
    'name_fx', l.name_fx, 'frame', l.frame, 'prestige', coalesce(l.prestige, 0))
  from (select 1) d left join public.yzy_leaderboard l on l.username = u
$$;
revoke all on function public.yzy__cosmetics_state(text) from public, anon, authenticated;

create or replace function public.yzy_cosmetics_get(p_username text, p_secret text) returns json
language plpgsql stable security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  return public.yzy__cosmetics_state(upper(btrim(p_username)));
end $$;

create or replace function public.yzy_cosmetic_buy(p_username text, p_secret text, p_item text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text := upper(btrim(coalesce(p_username,'')));
  c public.yzy_cosmetics_catalog%rowtype; pr int; bal int;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  select * into c from public.yzy_cosmetics_catalog where item_id = p_item;
  if not found then return json_build_object('ok', false, 'reason', 'item'); end if;
  select coalesce(prestige, 0) into pr from public.yzy_leaderboard where username = u for update;  -- serializes buys per player
  if not found then return json_build_object('ok', false, 'reason', 'no-board'); end if;
  if exists (select 1 from public.yzy_cosmetics_owned where username = u and item_id = p_item) then
    return public.yzy__cosmetics_state(u)::jsonb || '{"already":true}'::jsonb;
  end if;
  bal := pr - coalesce((select sum(price) from public.yzy_cosmetics_owned where username = u), 0);
  if c.price > bal then return json_build_object('ok', false, 'reason', 'funds', 'balance', bal); end if;
  insert into public.yzy_cosmetics_owned(username, item_id, price) values (u, p_item, c.price);
  return public.yzy__cosmetics_state(u);
end $$;

create or replace function public.yzy_cosmetic_equip(p_username text, p_secret text, p_kind text, p_item text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text := upper(btrim(coalesce(p_username,'')));
  c public.yzy_cosmetics_catalog%rowtype;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if p_kind not in ('fx','frame') then return json_build_object('ok', false, 'reason', 'kind'); end if;
  if p_item is not null then
    select * into c from public.yzy_cosmetics_catalog where item_id = p_item and kind = p_kind;
    if not found then return json_build_object('ok', false, 'reason', 'item'); end if;
    if c.price > 0 and not exists (select 1 from public.yzy_cosmetics_owned where username = u and item_id = p_item) then
      return json_build_object('ok', false, 'reason', 'not-owned');
    end if;
  end if;
  if p_kind = 'fx' then update public.yzy_leaderboard set name_fx = p_item where username = u;
  else update public.yzy_leaderboard set frame = p_item where username = u; end if;
  if not found then return json_build_object('ok', false, 'reason', 'no-board'); end if;
  return public.yzy__cosmetics_state(u);
end $$;

revoke all on function public.yzy_cosmetics_get(text, text) from public;
revoke all on function public.yzy_cosmetic_buy(text, text, text) from public;
revoke all on function public.yzy_cosmetic_equip(text, text, text, text) from public;
grant execute on function public.yzy_cosmetics_get(text, text) to anon, authenticated;
grant execute on function public.yzy_cosmetic_buy(text, text, text) to anon, authenticated;
grant execute on function public.yzy_cosmetic_equip(text, text, text, text) to anon, authenticated;

-- Weekly board exposes the equipped cosmetics (from the all-time row).
create or replace view public.yzy_weekly_board as
  select w.username, w.score, w.clicks, w.current_era, w.twitter_handle, w.updated_at, l.prestige, l.name_fx, l.frame
    from public.yzy_weekly w left join public.yzy_leaderboard l on l.username = w.username
   where w.week_start = public.yzy_week_start() and w.score > 0 and not (w.score > 1e12 and w.clicks < 5000);
grant select on public.yzy_weekly_board to anon, authenticated;
commit;
notify pgrst, 'reload schema';
