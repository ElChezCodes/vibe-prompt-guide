-- Follow-ups to arena_state_model_2026-10-26.sql (apply AFTER it), 2026-10-26
--
-- 1. pg_cron log retention + re-enable battle_lifecycle_job
-- 2. Song search: songs had RLS enabled with ZERO policies (unreadable by any
--    client), and the curated library lives in its own arena, so a new arena
--    could never find it.
-- 3. Battle creation restricted to the arena's real host.

begin;

-- ---------------------------------------------------------------- 1. cron
--
-- The 7GB incident was cron.job_run_details: one row per run of the
-- 1-second battle_lifecycle_job (86,400 rows/day), never pruned for 8 months.
-- The existing daily 3-day purge (job 10) would still let that job keep
-- ~260k rows. Now: purge every 10 min; the 1-second job keeps 1 hour of
-- history (~4k rows max), everything else keeps 3 days.
-- (cron.log_run = off would stop logging entirely, but it is a server-level
-- setting not changeable from SQL on hosted Supabase.)

select cron.unschedule(jobid) from cron.job where jobid = 10;

select cron.schedule(
  'cron_log_retention',
  '*/10 * * * *',
  $$
  delete from cron.job_run_details
  where (jobid = (select jobid from cron.job where jobname = 'battle_lifecycle_job')
         and end_time < now() - interval '1 hour')
     or end_time < now() - interval '3 days';
  $$
);

-- debug cruft (already inactive), see APP_STATE_AND_ROADMAP.md §2.5.13
select cron.unschedule(jobid) from cron.job where jobid = 7;

-- Safe to run again now: it only touches arenas with state = 'active' (just
-- the curated-library arena, which has no battles), since every legacy arena
-- was moved to 'expired' by the previous script.
select cron.alter_job(jobid, active := true) from cron.job where jobid = 9;

-- ---------------------------------------------------------------- 2. song search

-- The curated MVP library (seed_curated_songs_2026-10-25.sql). Songs are
-- arena-scoped, but battles/queues reference songs by id only, so library
-- songs can be proposed into any arena directly.
create or replace function public.library_arena_id()
returns uuid
language sql
immutable
as $$ select 'c8d99d16-4dad-498f-88ad-8a21fe15d341'::uuid $$;

create or replace function public.search_songs(p_arena_id uuid, p_query text)
returns table(id uuid, title text, artist text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.title, s.artist
  from songs s
  where exists (
          select 1 from participants p
          where p.arena_id = p_arena_id and p.identity_anchor_id = auth.uid())
    and s.arena_id in (p_arena_id, library_arena_id())
    and s.status = 'active'
    and s.source <> 'mock'
    and (s.title ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or s.artist ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
  order by s.title
  limit 20;
$$;

revoke all on function public.search_songs(uuid, text) from public, anon;
grant execute on function public.search_songs(uuid, text) to authenticated;

-- ---------------------------------------------------------------- 3. battle auth

-- The old policy trusted participants.is_host, which the client sets itself
-- on insert -- anyone could join as "host" and create battles.
drop policy if exists host_can_create_initial_battle on battles;
create policy host_can_create_initial_battle on battles
  for insert
  with check (exists (
    select 1 from arenas a
    where a.id = battles.arena_id and a.host_id = auth.uid()));

-- is_host = true only for the arena's actual host.
create policy participants_is_host_matches_arena on participants
  as restrictive for insert
  with check (
    is_host = false
    or exists (
      select 1 from arenas a
      where a.id = participants.arena_id and a.host_id = auth.uid()));

-- participant_can_update_self would otherwise let anyone flip is_host later.
create policy participants_update_is_host_matches_arena on participants
  as restrictive for update
  using (true)
  with check (
    is_host = false
    or exists (
      select 1 from arenas a
      where a.id = participants.arena_id and a.host_id = auth.uid()));

-- The create-battle Edge Function (service role, bypasses RLS) now checks
-- arenas.host_id against the caller's JWT itself -- see
-- supabase/functions/create-battle/index.ts.

commit;
