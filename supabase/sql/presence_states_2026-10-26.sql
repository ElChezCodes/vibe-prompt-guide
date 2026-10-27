-- Roadmap step 4: presence states ACTIVO / PASIVO / INACTIVO.
--
-- Spec: v4 §1.2 (= v3.2 "Estados de usuario"), Paso_1_Definitivo §3, Paso_2 §4,
-- PRD §5/§17. Computed server-side ON THE FLY from timestamps (no stored state,
-- no cron: the state is a pure function of time). The frontend only displays it.
--
--   ACTIVO   = connected and an action in the arena in the last 5 min
--              (participants.last_active_at, written by step 3)
--   PASIVO   = connected, no action in the last 5 min
--   INACTIVO = "Leave arena" (left_at), app closed, not seen for 10 min, or the
--              arena is no longer open
--
-- User decisions 2026-10-26 (step-4 chat):
--   * "Connected" = connection heartbeat. The app calls presence_heartbeat()
--     every 30 s on any screen (not the Stage View) -> participants.last_seen_at.
--     It is NOT activity (v4 §1.3): it never touches last_active_at, so it never
--     makes anyone ACTIVO nor keeps an arena alive (arena_last_activity ignores
--     it). INACTIVO after 10 min unseen: a grace for locked phones, whose
--     browsers freeze the page. Closing the tab sends presence_disconnect()
--     (pagehide) -> INACTIVO at once (Paso_2 §4.1, PRD §17).
--   * A linked music account is NOT required to be PASIVO (Paso_1 §3.2); it is
--     a step-9 condition to produce a passive vote (v4 §11.3).
--   * Live state + a frozen snapshot per battle at lock-in
--     (battle_presence_snapshots), which step 9 (passive vote) and the
--     0.4/0.5 PB ratio read. Re-activating before a battle ("entre batallas")
--     needs nothing special: the state is live until that battle's lock-in.
--   * "ACTIVO -> PASIVO during the battle: the active vote stays but can't be
--     changed" is read as: the vote keeps counting as active and is never
--     replaced by a passive vote (step 9 only votes for participants with no
--     votes row); tapping again is an action, so the user is ACTIVO again and
--     the change is accepted. No RLS change.
--   * Re-entering (enter_arena) is activity, so INACTIVO -> ACTIVO (v4 over
--     Paso_1 §3.3 "entra como pasivo").

-- 1. Columns ------------------------------------------------------------------
alter table public.participants
  add column if not exists last_seen_at timestamptz,
  add column if not exists disconnected_at timestamptz;

-- 2. The state function -------------------------------------------------------
create or replace function public.presence_state(
  p_last_active_at timestamptz,
  p_last_seen_at timestamptz,
  p_disconnected_at timestamptz,
  p_left_at timestamptz,
  p_arena_state text,
  p_at timestamptz default now())
returns text
language sql
immutable
as $$
  select case
    when p_arena_state is distinct from 'waiting' and p_arena_state is distinct from 'active'
      then 'inactive'
    when p_left_at is not null then 'inactive'
    -- connection: heartbeat grace and explicit disconnect
    when p_last_seen_at is null or p_last_seen_at < p_at - interval '10 minutes' then 'inactive'
    when p_disconnected_at is not null and p_disconnected_at >= p_last_seen_at then 'inactive'
    -- activity window
    when p_last_active_at >= p_at - interval '5 minutes' then 'active'
    else 'passive'
  end;
$$;

-- RLS-respecting view (security_invoker) for reads; SECURITY DEFINER code sees all rows
create or replace view public.participant_presence
with (security_invoker = true) as
select
  p.id as participant_id,
  p.arena_id,
  p.identity_anchor_id,
  p.is_host,
  presence_state(p.last_active_at, p.last_seen_at, p.disconnected_at, p.left_at, a.state) as state,
  p.last_active_at,
  p.last_seen_at
from participants p
join arenas a on a.id = p.arena_id;

grant select on public.participant_presence to authenticated;

-- 3. Guard: clients can't write the connection columns either ----------------
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
      new.last_seen_at := now();
      new.disconnected_at := null;
    else
      new.joined_at := old.joined_at;
      new.last_active_at := old.last_active_at;
      new.last_seen_at := old.last_seen_at;
      new.disconnected_at := old.disconnected_at;
      new.arena_id := old.arena_id;
      new.identity_anchor_id := old.identity_anchor_id;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end;
$$;

-- 4. Activity implies connection ---------------------------------------------
create or replace function public.touch_participant_activity(p_arena_id uuid, p_uid uuid)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update participants
  set last_active_at = now(),
      last_seen_at = now(),
      disconnected_at = null,
      updated_at = now()
  where arena_id = p_arena_id
    and identity_anchor_id = p_uid;
$$;

revoke all on function public.touch_participant_activity(uuid, uuid) from public, anon, authenticated;

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
    insert into participants (arena_id, identity_anchor_id, is_host, joined_at, last_active_at, last_seen_at)
    values (p_arena_id, v_uid, v_arena.host_id = v_uid, now(), now(), now())
    on conflict (arena_id, identity_anchor_id) do update
      set left_at = null,
          last_active_at = now(),
          last_seen_at = now(),
          disconnected_at = null,
          updated_at = now()
    returning *;
end;
$$;

revoke all on function public.enter_arena(uuid) from public, anon;
grant execute on function public.enter_arena(uuid) to authenticated;

-- 5. Heartbeat / disconnect (connection only, never activity) -----------------
-- Both act on the caller's current arena, same rule as get_current_arena():
-- the most recent open arena they're in and haven't left.
create or replace function public.presence_heartbeat()
returns void
language sql
security definer
set search_path to 'public'
as $$
  update participants
  set last_seen_at = now(),
      disconnected_at = null
  where id = (
    select p.id from participants p
    join arenas a on a.id = p.arena_id
    where p.identity_anchor_id = auth.uid()
      and p.left_at is null
      and a.state in ('waiting', 'active')
    order by p.joined_at desc
    limit 1);
$$;

create or replace function public.presence_disconnect()
returns void
language sql
security definer
set search_path to 'public'
as $$
  update participants
  set disconnected_at = now()
  where id = (
    select p.id from participants p
    join arenas a on a.id = p.arena_id
    where p.identity_anchor_id = auth.uid()
      and p.left_at is null
      and a.state in ('waiting', 'active')
    order by p.joined_at desc
    limit 1);
$$;

revoke all on function public.presence_heartbeat() from public, anon;
revoke all on function public.presence_disconnect() from public, anon;
grant execute on function public.presence_heartbeat() to authenticated;
grant execute on function public.presence_disconnect() to authenticated;

-- 6. Display read: own state + arena counts (members and host only) ----------
create or replace function public.get_arena_presence(p_arena_id uuid)
returns table(my_state text, active_count int, passive_count int, inactive_count int)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not exists (select 1 from participants where arena_id = p_arena_id and identity_anchor_id = auth.uid())
     and not exists (select 1 from arenas where id = p_arena_id and host_id = auth.uid()) then
    raise exception 'not a member of this arena' using errcode = '42501';
  end if;

  return query
    select
      max(pp.state) filter (where pp.identity_anchor_id = auth.uid()),
      (count(*) filter (where pp.state = 'active'))::int,
      (count(*) filter (where pp.state = 'passive'))::int,
      (count(*) filter (where pp.state = 'inactive'))::int
    from participant_presence pp
    where pp.arena_id = p_arena_id;
end;
$$;

revoke all on function public.get_arena_presence(uuid) from public, anon;
grant execute on function public.get_arena_presence(uuid) to authenticated;

-- 7. Snapshot at lock-in (for step 9 and the 0.4/0.5 PB ratio) ---------------
-- One row per participant of the arena (all three states), frozen when
-- process_battle_lifecycle sets battles.lockin_at. Clients can only read.
create table if not exists public.battle_presence_snapshots (
  battle_id uuid not null references public.battles(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  arena_id uuid not null,
  identity_anchor_id uuid not null,
  state text not null check (state in ('active', 'passive', 'inactive')),
  last_active_at timestamptz,
  captured_at timestamptz not null default now(),
  primary key (battle_id, participant_id)
);

alter table public.battle_presence_snapshots enable row level security;
revoke insert, update, delete, truncate on public.battle_presence_snapshots from anon, authenticated;

drop policy if exists battle_presence_snapshots_select on public.battle_presence_snapshots;
create policy battle_presence_snapshots_select on public.battle_presence_snapshots
  for select to authenticated
  using (identity_anchor_id = auth.uid()
         or arena_id in (select id from arenas where host_id = auth.uid()));

create or replace function public.snapshot_presence_at_lockin()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into battle_presence_snapshots (battle_id, participant_id, arena_id, identity_anchor_id, state, last_active_at)
  select new.id, pp.participant_id, pp.arena_id, pp.identity_anchor_id, pp.state, pp.last_active_at
  from participant_presence pp
  where pp.arena_id = new.arena_id
  on conflict (battle_id, participant_id) do nothing;
  return null;
end;
$$;

drop trigger if exists trg_battles_snapshot_presence on public.battles;
create trigger trg_battles_snapshot_presence
  after update of lockin_at on public.battles
  for each row
  when (old.lockin_at is null and new.lockin_at is not null)
  execute function public.snapshot_presence_at_lockin();

-- 8. Retention: snapshots go with the votes (Block 5 §6, 30 days) ------------
create or replace function public.purge_old_arena_votes(p_retention interval default '30 days'::interval)
returns integer
language plpgsql
security definer
set search_path to 'public'
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

    delete from battle_presence_snapshots where arena_id = r.id;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
