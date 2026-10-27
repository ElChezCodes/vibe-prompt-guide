-- Roadmap step 3: presence tracking infrastructure.
--
-- participants.last_active_at = the participant's last action in the arena,
-- written ONLY server-side. v4 §1.2: "cualquier acción dentro de Arena (votar,
-- cambiar voto, proponer, comentar, usar Jukebox, entrar a Arena)". A heartbeat
-- is NOT activity (v4 §1.3: heartbeat criteria replaced). Comments/Jukebox don't
-- exist yet. ACTIVO/PASIVO/INACTIVO transitions are step 4.
--
-- What counts (user decisions 2026-10-26):
--   * entering the arena: every Battle Room entry (and the host's Lobby),
--     including reloads and coming back from other app tabs -> enter_arena()
--   * voting, switching AND toggling off a vote (accepted writes only;
--     system/passive votes never count)
--   * proposing a song (queues row stamped with proposed_by)
--   * the host pressing Start battles (waiting -> active); the host otherwise
--     counts the same as everyone else
--
-- Anti-forgery: clients keep table-level UPDATE on participants, so a BEFORE
-- trigger pins last_active_at / joined_at (and the row's identity) to their
-- server-side values for client roles. SECURITY DEFINER code runs as the
-- owner, so current_user tells the two apart.

-- 1. Guard ------------------------------------------------------------------
create or replace function public.guard_participant_presence()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      -- a client insert is an entry into the arena
      new.joined_at := now();
      new.last_active_at := now();
    else
      new.joined_at := old.joined_at;
      new.last_active_at := old.last_active_at;
      new.arena_id := old.arena_id;
      new.identity_anchor_id := old.identity_anchor_id;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_participants_guard_presence on public.participants;
create trigger trg_participants_guard_presence
  before insert or update on public.participants
  for each row execute function public.guard_participant_presence();

-- 2. Internal touch (not callable by clients) -------------------------------
create or replace function public.touch_participant_activity(p_arena_id uuid, p_uid uuid)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update participants
  set last_active_at = now(),
      updated_at = now()
  where arena_id = p_arena_id
    and identity_anchor_id = p_uid;
$$;

revoke all on function public.touch_participant_activity(uuid, uuid) from public, anon, authenticated;

-- 3. Entering the arena -----------------------------------------------------
-- Replaces the client-side insert-or-fetch in ensureParticipant. Idempotent;
-- clears a previous "Leave arena" (left_at) and stamps the entry. is_host is
-- decided here from arenas.host_id, never from the client. Closed arenas: an
-- existing member gets their row back untouched, a non-member is rejected
-- (same outcome as the participants_require_open_arena RLS policy).
create or replace function public.enter_arena(p_arena_id uuid)
returns setof public.participants
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_arena arenas%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_arena from arenas where id = p_arena_id;
  if not found then
    raise exception 'arena not found' using errcode = 'P0002';
  end if;

  if v_arena.state not in ('waiting', 'active') then
    return query
      select * from participants
      where arena_id = p_arena_id and identity_anchor_id = v_uid;
    if not found then
      raise exception 'arena is %', v_arena.state using errcode = '42501';
    end if;
    return;
  end if;

  return query
    insert into participants (arena_id, identity_anchor_id, is_host, joined_at, last_active_at)
    values (p_arena_id, v_uid, v_arena.host_id = v_uid, now(), now())
    on conflict (arena_id, identity_anchor_id) do update
      set left_at = null,
          last_active_at = now(),
          updated_at = now()
    returning *;
end;
$$;

revoke all on function public.enter_arena(uuid) from public, anon;
grant execute on function public.enter_arena(uuid) to authenticated;

-- 4. Votes: cast / switch / toggle off --------------------------------------
-- AFTER trigger, so only writes that passed RLS (phase rules) count.
create or replace function public.touch_activity_on_vote()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is not null
     and new.identity_anchor_id = auth.uid()
     and new.vote_type <> 'passive' then
    perform touch_participant_activity(new.arena_id, auth.uid());
  end if;
  return null;
end;
$$;

drop trigger if exists trg_votes_touch_activity on public.votes;
create trigger trg_votes_touch_activity
  after insert or update on public.votes
  for each row execute function public.touch_activity_on_vote();

-- 5. Proposals ---------------------------------------------------------------
-- proposed_by is stamped from auth.uid() by trg_queues_stamp_proposer (NULL for
-- system/cron inserts, which therefore don't count).
create or replace function public.touch_activity_on_proposal()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.proposed_by is not null then
    perform touch_participant_activity(new.arena_id, new.proposed_by);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_queues_touch_activity on public.queues;
create trigger trg_queues_touch_activity
  after insert on public.queues
  for each row execute function public.touch_activity_on_proposal();

-- 6. Host pressing Start battles (start_arena_battles: waiting -> active) -----
create or replace function public.touch_activity_on_arena_start()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is not null and new.host_id = auth.uid() then
    perform touch_participant_activity(new.id, auth.uid());
  end if;
  return null;
end;
$$;

drop trigger if exists trg_arenas_touch_activity_on_start on public.arenas;
create trigger trg_arenas_touch_activity_on_start
  after update of state on public.arenas
  for each row
  when (old.state = 'waiting' and new.state = 'active')
  execute function public.touch_activity_on_arena_start();

-- 7. Backfill ----------------------------------------------------------------
-- Best known last action for existing rows (entry, own votes, own proposals).
update participants p
set last_active_at = greatest(
  p.joined_at,
  (select max(greatest(v.created_at, v.updated_at)) from votes v
    where v.arena_id = p.arena_id and v.identity_anchor_id = p.identity_anchor_id
      and v.vote_type <> 'passive'),
  (select max(q.created_at) from queues q
    where q.arena_id = p.arena_id and q.proposed_by = p.identity_anchor_id))
where p.last_active_at is null;
