-- yzy_delete: owner-verified delete of a player's ¥ Board presence.
-- Removes cloud save, all-time row AND all weekly rows; p_release also frees the name claim.
-- Same signature as before (client calls rpc/yzy_delete), so grants are preserved.
create or replace function public.yzy_delete(p_username text, p_secret text, p_release boolean default false)
returns json language plpgsql security definer set search_path to 'public'
as $function$
declare a text := public.yzy__auth(p_username, p_secret, false); u text := upper(btrim(coalesce(p_username,'')));
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  delete from public.yzy_saves where username = u;
  delete from public.yzy_leaderboard where username = u;
  delete from public.yzy_weekly where username = u;
  if p_release then delete from public.yzy_names where username_key = public.yzy_name_key(p_username); end if;
  return json_build_object('ok', true);
end $function$;
grant execute on function public.yzy_delete(text, text, boolean) to anon, authenticated;
