-- yzy_contest_place: owner-verified lookup of the caller's place (1-5) among the first
-- 5 non-ZZ players to reach Trillionbear (yzy_trillionbear_firsts by reached_at). Read-only.
create or replace function public.yzy_contest_place(p_username text, p_secret text)
returns integer language plpgsql stable security definer set search_path to 'public'
as $function$
declare a text := public.yzy__auth(p_username, p_secret, false); u text := upper(btrim(coalesce(p_username,''))); r integer;
begin
  if a <> 'ok' then return null; end if;
  select t.place into r from (
    select username, row_number() over (order by reached_at asc, username asc)::int as place
    from public.yzy_trillionbear_firsts where username not like 'ZZ%'
    order by reached_at asc, username asc limit 5) t
  where t.username = u;
  return r;
end $function$;
revoke all on function public.yzy_contest_place(text, text) from public;
grant execute on function public.yzy_contest_place(text, text) to anon, authenticated;
