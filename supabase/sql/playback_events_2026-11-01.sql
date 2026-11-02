-- Playback event log (2026-11-01): the 1-hour test felt "erratic" (Resume took
-- 3 clicks) and the Edge Function logs aren't reachable from here, so
-- spotify-host writes what it did to the host's Spotify, and why. Service-only,
-- kept 7 days. Kinds: pause, resume (button/auto, ok/failed, attempts),
-- put_back, kick, skip_to_lockin, control_mode.
create table if not exists public.playback_events (
  id bigint generated always as identity primary key,
  arena_id uuid not null references public.arenas(id) on delete cascade,
  at timestamptz not null default now(),
  kind text not null,
  detail jsonb not null default '{}'::jsonb
);
create index if not exists playback_events_arena_at_idx on public.playback_events (arena_id, at);
alter table public.playback_events enable row level security;
revoke all on public.playback_events from public, anon, authenticated;
grant select, insert, delete on public.playback_events to service_role;

create or replace function public.log_playback_event(p_arena_id uuid, p_kind text, p_detail jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path to 'public'
as $$
  insert into playback_events (arena_id, kind, detail) values (p_arena_id, p_kind, coalesce(p_detail, '{}'::jsonb));
  delete from playback_events where at < now() - interval '7 days';
$$;
revoke all on function public.log_playback_event(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.log_playback_event(uuid, text, jsonb) to service_role;

-- The host's mode choice is logged too
create or replace function public.set_arena_control_mode(p_arena_id uuid, p_mode text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_mode not in ('auto', 'manual') then
    raise exception 'invalid mode' using errcode = '22023';
  end if;
  if not exists (select 1 from arenas where id = p_arena_id and host_id = auth.uid()) then
    raise exception 'only the host can change this' using errcode = '42501';
  end if;
  update arena_playback
  set control_mode = p_mode, manual_change_at = null, strikes = 0, strike_reason = null, updated_at = now()
  where arena_id = p_arena_id;
  perform log_playback_event(p_arena_id, 'control_mode', jsonb_build_object('mode', p_mode));
  return p_mode;
end;
$function$;
