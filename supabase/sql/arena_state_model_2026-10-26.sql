-- Roadmap step 1: real Arena state model + mood (2026-10-26)
--
-- Spec: Dev/Backend/Music_Fighter_Backend_Block_2_States_and_Rules.txt §1-2,
-- Block_3 §1-2 (create = waiting + mood persisted; join validates waiting|active),
-- Block_5 §6 (arenas have a TTL).
--
-- Live state before this script (read via `supabase db query --linked`):
--   arenas.state: free text, no CHECK, no default. Values: 'inactive' (101 rows,
--     all legacy test arenas), 'active' (1 row: "MVP Curated Library", the
--     song-container arena from seed_curated_songs_2026-10-25.sql).
--   arenas.mood:  default was the literal STRING 'NULL'. Values: 'NULL' (33),
--     'warmup' (70, all on inactive legacy rows -- warm-up is not a mood, it is
--     Arena.warmup_song_id per Block 2 §3, roadmap step 2). Never read anywhere.
--   create_arena(p_name, p_host_id): hardcoded state 'active', trusted a
--     client-supplied host id.
--   No arena-state transitions anywhere else; battle_lifecycle_job (pg_cron)
--     only processes arenas with state = 'active'.
--
-- State machine after this script (backend-only transitions, like battles.state):
--   create_arena          -> waiting  (mood required)
--   start_arena_battles   waiting -> active   (host only)
--   end_arena             waiting|active -> finished (host only; ending from
--                         waiting is a user decision 2026-10-26, beyond Block 2 §1.1)
--   expire_stale_arenas   waiting -> expired  (pg_cron, idle TTL)
--
-- Data mapping: 'inactive' -> 'expired' (abandoned, never properly finished --
-- exactly what Block 2 §1.4 describes). The curated-library arena stays 'active'
-- (unchanged), so it never expires and remains usable for testing proposals.

begin;

-- ---------------------------------------------------------------- data + constraints

alter table arenas alter column mood drop default;
update arenas set mood = null where mood in ('NULL', 'warmup');

update arenas set state = 'expired', updated_at = now() where state = 'inactive';

alter table arenas alter column state set default 'waiting';

alter table arenas add constraint arenas_state_check
  check (state in ('waiting', 'active', 'finished', 'expired'));

-- Block 2 §2 suggested values, expanded to 63 (user-approved 2026-10-26).
-- Keep src/integrations/supabase/arenas.ts ARENA_MOODS in sync.
alter table arenas add constraint arenas_mood_check
  check (mood is null or mood in (
    'chill', 'party', 'energetic', 'romantic', 'dance', 'workout', 'focus', 'sunset', 'brunch', 'late-night', 'after-party', 'lounge', 'karaoke', 'festival', 'tropical', 'feel-good', 'melancholic', 'epic',
    'pop', 'rock', 'indie', 'alternative', 'metal', 'punk', 'hip-hop', 'r-and-b', 'soul', 'funk', 'jazz', 'blues', 'country', 'folk', 'acoustic', 'classical', 'gospel', 'reggae', 'afrobeats', 'k-pop', 'lo-fi', 'ambient',
    'electronic', 'house', 'techno', 'trance', 'drum-and-bass', 'dubstep', 'synthwave', 'disco',
    'latin', 'reggaeton', 'salsa', 'bachata', 'cumbia', 'merengue', 'flamenco', 'rumba', 'tango',
    '70s', '80s', '90s', '2000s', 'throwback',
    'custom'));

-- Block 2 §1.1: a waiting arena always has a mood defined. Legacy rows
-- (expired, and the library arena) are allowed to have none.
alter table arenas add constraint arenas_waiting_requires_mood
  check (state <> 'waiting' or mood is not null);

-- ---------------------------------------------------------------- transitions

drop function if exists public.create_arena(text, uuid);

create function public.create_arena(p_name text, p_mood text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_arena_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- mood validity/presence is enforced by arenas_mood_check +
  -- arenas_waiting_requires_mood
  insert into arenas (name, host_id, state, mood)
  values (p_name, auth.uid(), 'waiting', p_mood)
  returning id into v_arena_id;

  perform ensure_mock_songs_for_arena(v_arena_id);

  return v_arena_id;
end;
$$;

create function public.start_arena_battles(p_arena_id uuid)
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
    raise exception 'only the host can start battles' using errcode = '42501';
  end if;

  -- idempotent: host re-entering an arena that is already running
  if v_arena.state = 'active' then
    return 'active';
  end if;
  if v_arena.state <> 'waiting' then
    raise exception 'arena is %', v_arena.state using errcode = '22023';
  end if;

  update arenas
  set state = 'active', started_at = now(), updated_at = now()
  where id = p_arena_id;

  return 'active';
end;
$$;

create function public.end_arena(p_arena_id uuid)
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

  -- battle_lifecycle_job only processes 'active' arenas, so any in-flight
  -- battle stops advancing here; votes on it are blocked by
  -- votes_require_active_arena below.
  update arenas
  set state = 'finished', ended_at = now(), updated_at = now()
  where id = p_arena_id;

  return 'finished';
end;
$$;

-- Block 2 §1.1: waiting -> expired on prolonged inactivity. The spec gives no
-- number; 6h is a judgment call. "Activity" uses only signals that are
-- actually written today (participants.last_active_at is not, until step 3).
create function public.expire_stale_arenas(p_idle interval default interval '6 hours')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update arenas a
  set state = 'expired', updated_at = now()
  where a.state = 'waiting'
    and greatest(
          a.created_at,
          a.updated_at,
          (select max(greatest(p.joined_at, coalesce(p.last_active_at, p.joined_at)))
             from participants p where p.arena_id = a.id),
          (select max(q.created_at) from queues q where q.arena_id = a.id)
        ) < now() - p_idle;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.create_arena(text, text) from public, anon;
revoke all on function public.start_arena_battles(uuid) from public, anon;
revoke all on function public.end_arena(uuid) from public, anon;
revoke all on function public.expire_stale_arenas(interval) from public, anon, authenticated;
grant execute on function public.create_arena(text, text) to authenticated;
grant execute on function public.start_arena_battles(uuid) to authenticated;
grant execute on function public.end_arena(uuid) to authenticated;

-- ---------------------------------------------------------------- enforcement

-- Battles exist only in an active arena (Block 2 §1.1: "No hay batallas
-- activas" in waiting). A trigger rather than RLS so it also covers the
-- service-role create-battle Edge Function.
create function public.enforce_battle_arena_active()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not exists (select 1 from arenas where id = new.arena_id and state = 'active') then
    raise exception 'battles can only be created in an active arena' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger trg_battle_requires_active_arena
  before insert on battles
  for each row execute function enforce_battle_arena_active();

-- Restrictive policies AND with the existing permissive ones, so none of the
-- existing vote/queue/participant policies need rewriting.

-- Votes only while the arena is active (finished: "No se aceptan votos").
create policy votes_require_active_arena on votes
  as restrictive for insert
  with check (exists (
    select 1 from battles b join arenas a on a.id = b.arena_id
    where b.id = votes.battle_id and a.state = 'active'));

create policy votes_update_require_active_arena on votes
  as restrictive for update
  using (exists (
    select 1 from battles b join arenas a on a.id = b.arena_id
    where b.id = votes.battle_id and a.state = 'active'))
  with check (exists (
    select 1 from battles b join arenas a on a.id = b.arena_id
    where b.id = votes.battle_id and a.state = 'active'));

-- Proposals in waiting and active only (Block 2 §8).
create policy queues_require_open_arena on queues
  as restrictive for insert
  with check (exists (
    select 1 from arenas a
    where a.id = queues.arena_id and a.state in ('waiting', 'active')));

-- Join only waiting/active arenas (Block 3 §2). Re-entering a finished arena
-- still works: ensureParticipant fetches the existing row, no insert.
create policy participants_require_open_arena on participants
  as restrictive for insert
  with check (exists (
    select 1 from arenas a
    where a.id = participants.arena_id and a.state in ('waiting', 'active')));

-- Expired arenas are not visible to users (Block 2 §1.4). Hosts still see
-- their own via host_select_arena.
drop policy arena_select_authenticated on arenas;
create policy arena_select_authenticated on arenas
  for select
  using (auth.uid() is not null and state <> 'expired');

-- Block 2 §10: arena changes propagate in realtime (Battle Room reacts to
-- active/finished without polling).
alter publication supabase_realtime add table arenas;

commit;

select cron.schedule('arena_expiry_job', '*/15 * * * *', $$select public.expire_stale_arenas()$$);
