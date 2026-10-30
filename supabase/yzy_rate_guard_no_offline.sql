-- Offline earnings were removed from the client. Drop the offline allowance
-- (0.5 × 2.61e14 b/s × up to 8h) from the bars rate guard. Keeps 4e14 b/s × elapsed + 1e9 slack.
-- Click guard (75/s + 500) is unchanged. No client sends an offline param; the
-- allowance only lived here, so this is a drop-in replacement.
create or replace function public.yzy__max_gain(secs numeric)
returns numeric language sql immutable
as $function$ select 4e14 * greatest(secs, 0) + 1e9 $function$;
