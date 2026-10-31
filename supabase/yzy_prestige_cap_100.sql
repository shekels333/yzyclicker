-- Cap prestige at 100 (was 500). DO NOT APPLY without approval.
-- The only server clamp lives in yzy__set_prestige, called by yzy_lb_submit
-- (yzy_weekly_submit_v2 ignores p_prestige, so it needs no change).
-- Live max prestige when written: 0, rows > 100: 0.
begin;

create or replace function public.yzy__set_prestige(u text, p integer)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  if p is null then return; end if;
  update public.yzy_leaderboard
     set prestige = least(100, greatest(coalesce(prestige, 0), least(greatest(p, 0), 100, coalesce(prestige, 0) + 3)))
   where username = u;
end $function$;

-- YzY Tokens earned = prestige, so max 100.
create or replace function public.yzy__cosmetics_state(u text)
 returns json language sql stable security definer set search_path to 'public'
as $function$
  select json_build_object('ok', true,
    'earned', least(100, coalesce(l.prestige, 0)),
    'spent',  coalesce((select sum(price) from public.yzy_cosmetics_owned o where o.username = u), 0),
    'balance', least(100, coalesce(l.prestige, 0)) - coalesce((select sum(price) from public.yzy_cosmetics_owned o where o.username = u), 0),
    'owned',  coalesce((select json_agg(item_id order by item_id) from public.yzy_cosmetics_owned o where o.username = u), '[]'::json),
    'name_fx', l.name_fx, 'frame', l.frame, 'prestige', least(100, coalesce(l.prestige, 0)))
  from (select 1) d left join public.yzy_leaderboard l on l.username = u
$function$;

update public.yzy_leaderboard set prestige = 100 where prestige > 100;
alter table public.yzy_leaderboard drop constraint if exists yzy_leaderboard_prestige_cap;
alter table public.yzy_leaderboard add constraint yzy_leaderboard_prestige_cap check (prestige is null or prestige between 0 and 100);

commit;
notify pgrst, 'reload schema';
