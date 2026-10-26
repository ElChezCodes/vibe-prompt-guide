-- Arena lifecycle closure: auto-finish, in-flight battles, vote retention
-- 2026-10-26 (completes roadmap step 1; user decisions of 2026-10-26)
--
-- 1. active -> finished after 2h without activity (Block 2 §1.2 "Tiempo
--    máximo alcanzado"; the spec gives no number). Before this, an abandoned
--    active arena ran battle_lifecycle_job forever.
-- 2. When an arena finishes, its open battle is closed: kept as-is if already
--    decided at lock-in (normal win, already queued to playlist_queue),
--    otherwise completed with resolution_type = 'cancelled' (no winner,
--    nothing queued). Also cleans up the open battles already left in
--    finished/expired arenas.
-- 3. Block 5 §6 retention: 30 days after a finished/expired arena closes,
--    snapshot each battle's final tally (aggregate participation is kept)
--    and delete the individual vote rows. Arena, mood, songs, results stay.

begin;

-- ---------------------------------------------------------------- schema

alter table battles drop constraint battles_resolution_type_check;
alter table battles add constraint battles_resolution_type_check
  check (resolution_type = any (array['normal', 'sudden_death', 'draw', 'cancelled']));

alter table battles
  add column final_votes_a integer,
  add column final_votes_b integer;

alter table arenas add column votes_purged_at timestamptz;

-- ---------------------------------------------------------------- helpers (internal)

-- Latest participant-driven activity. Battles are deliberately not counted:
-- the cron creates them on its own, so they'd keep an abandoned arena alive.
create function public.arena_last_activity(p_arena_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    a.created_at,
    a.started_at,
    a.updated_at,
    (select max(greatest(p.joined_at, coalesce(p.last_active_at, p.joined_at)))
       from participants p where p.arena_id = a.id),
    (select max(q.created_at) from queues q where q.arena_id = a.id),
    (select max(greatest(v.created_at, v.updated_at))
       from votes v join battles b on b.id = v.battle_id where b.arena_id = a.id))
  from arenas a
  where a.id = p_arena_id;
$$;

create function public.close_open_battles(p_arena_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cancelled integer;
begin
  -- Already decided at lock-in: complete it, keep its result
  update battles
  set state = 'completed', ended_at = coalesce(ended_at, now()), updated_at = now()
  where arena_id = p_arena_id and state = 'closing' and resolution_type is not null;

  -- Undecided (pending, active, or Sudden Death in progress)
  update battles
  set state = 'completed',
      resolution_type = 'cancelled',
      winner_song_id = null,
      sudden_death_active = false,
      ended_at = now(),
      updated_at = now()
  where arena_id = p_arena_id and state in ('pending', 'active', 'closing');

  get diagnostics v_cancelled = row_count;
  return v_cancelled;
end;
$$;

-- Arena first, so battle_lifecycle_job (active arenas only) stops touching it
create function public.finish_arena(p_arena_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update arenas
  set state = 'finished', ended_at = now(), updated_at = now()
  where id = p_arena_id;

  perform close_open_battles(p_arena_id);
end;
$$;

-- ---------------------------------------------------------------- transitions

create or replace function public.end_arena(p_arena_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_arena arenas%rowtype;
begin
  select * into v_arena from arenas where id = p_arena_id for update;

  if not found then
    raise exception 'arena not found' using errcode = 'P0002';
  end if;
  if v_arena.host_id is distinct from auth.uid() then
    raise exception 'only the host can end the arena' using errcode = '42501';
  end if;

  if v_arena.state = 'finished' then
    return 'finished';
  end if;
  if v_arena.state not in ('waiting', 'active') then
    raise exception 'arena is %', v_arena.state using errcode = '22023';
  end if;

  perform finish_arena(p_arena_id);

  return 'finished';
end;
$$;

-- Called by arena_expiry_job every 15 min.
--   waiting, idle 6h -> expired   (Block 2 §1.1)
--   active,  idle 2h -> finished  (Block 2 §1.2), never the curated library
drop function public.expire_stale_arenas(interval);

create function public.expire_stale_arenas(
  p_waiting_idle interval default interval '6 hours',
  p_active_idle interval default interval '2 hours')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired integer;
  v_finished integer := 0;
  r record;
begin
  update arenas a
  set state = 'expired', updated_at = now()
  where a.state = 'waiting'
    and arena_last_activity(a.id) < now() - p_waiting_idle;
  get diagnostics v_expired = row_count;

  for r in
    select a.id from arenas a
    where a.state = 'active'
      and a.id <> library_arena_id()
      and arena_last_activity(a.id) < now() - p_active_idle
  loop
    perform finish_arena(r.id);
    v_finished := v_finished + 1;
  end loop;

  return v_expired + v_finished;
end;
$$;

-- ---------------------------------------------------------------- retention

-- Final tally uses the same rule as arena_live_state (active votes only;
-- sudden_death votes only once Sudden Death started).
create function public.purge_old_arena_votes(p_retention interval default interval '30 days')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select id from arenas
    where state in ('finished', 'expired')
      and votes_purged_at is null
      and coalesce(ended_at, updated_at) < now() - p_retention
  loop
    update battles b
    set final_votes_a = c.va, final_votes_b = c.vb
    from (
      select b2.id,
        count(v.id) filter (where v.song_id = b2.song_a_id and v.status = 'active'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as va,
        count(v.id) filter (where v.song_id = b2.song_b_id and v.status = 'active'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as vb
      from battles b2
      left join votes v on v.battle_id = b2.id
      where b2.arena_id = r.id
      group by b2.id
    ) c
    where b.id = c.id;

    delete from votes v using battles b
    where v.battle_id = b.id and b.arena_id = r.id;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.arena_last_activity(uuid) from public, anon, authenticated;
revoke all on function public.close_open_battles(uuid) from public, anon, authenticated;
revoke all on function public.finish_arena(uuid) from public, anon, authenticated;
revoke all on function public.expire_stale_arenas(interval, interval) from public, anon, authenticated;
revoke all on function public.purge_old_arena_votes(interval) from public, anon, authenticated;

-- ---------------------------------------------------------------- one-time cleanup

-- Open battles already stranded in finished/expired arenas (25 on 2026-10-26)
select close_open_battles(a.id)
from arenas a
where a.state in ('finished', 'expired')
  and exists (select 1 from battles b
              where b.arena_id = a.id and b.state in ('pending', 'active', 'closing'));

commit;

select cron.schedule('arena_vote_purge_job', '0 4 * * *', $$select public.purge_old_arena_votes()$$);
