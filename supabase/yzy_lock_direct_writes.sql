-- Phase 2 (after the new client is live): all writes only via the secret-checked RPCs.
drop policy if exists "allow_delete" on public.yzy_saves;
drop policy if exists "allow_public_read" on public.yzy_saves;
drop policy if exists "allow_update" on public.yzy_saves;
drop policy if exists "allow_upsert" on public.yzy_saves;
drop policy if exists "anyone can delete" on public.yzy_leaderboard;
drop policy if exists "anyone can update" on public.yzy_leaderboard;
drop policy if exists "anyone can upsert" on public.yzy_leaderboard;
revoke all on public.yzy_saves, public.yzy_leaderboard, public.yzy_weekly, public.yzy_weekly_board from anon, authenticated;
grant select on public.yzy_leaderboard, public.yzy_weekly, public.yzy_weekly_board to anon, authenticated;
revoke all on function public.yzy_weekly_submit(text, numeric, numeric, text, text) from public, anon, authenticated;
