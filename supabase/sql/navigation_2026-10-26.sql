-- Roadmap step 2b: functional in-app navigation.
--
-- 1. participants.left_at: "Salir de la arena" is an explicit exit (Paso_2 §4.1,
--    user decision 2026-10-26: browsing other app screens does NOT leave the
--    arena). Re-entering the arena clears it. Step 3/4 presence reuses it.
-- 2. get_current_arena(): the caller's current arena (most recent open arena
--    they are in and have not left). Drives "Volver a tu arena" and the
--    Arena/Proponer tabs, so it survives reloads.
-- 3. queues.proposed_by: who proposed a queued song, stamped server-side from
--    auth.uid() (not client-forgeable; NULL for system/cron inserts), so the
--    Battle Room modal and the Proponer screen show the same "my proposals".
--    Rows are deleted when pull_next_battle_songs puts them in a battle, so
--    "my proposals" = still queued.

-- 1 -------------------------------------------------------------------------
alter table public.participants add column if not exists left_at timestamptz;

create or replace function public.leave_arena(p_arena_id uuid)
returns void
language sql
security invoker
set search_path to 'public'
as $$
  update participants
  set left_at = now()
  where arena_id = p_arena_id
    and identity_anchor_id = auth.uid();
$$;

revoke all on function public.leave_arena(uuid) from public, anon;
grant execute on function public.leave_arena(uuid) to authenticated;

-- 2 -------------------------------------------------------------------------
create or replace function public.get_current_arena()
returns table (arena_id uuid, arena_code text, name text, state text, is_host boolean)
language sql
stable
security invoker
set search_path to 'public'
as $$
  select a.id, a.arena_code, a.name, a.state, (a.host_id = auth.uid())
  from participants p
  join arenas a on a.id = p.arena_id
  where p.identity_anchor_id = auth.uid()
    and p.left_at is null
    and a.state in ('waiting', 'active')
  order by p.joined_at desc
  limit 1;
$$;

revoke all on function public.get_current_arena() from public, anon;
grant execute on function public.get_current_arena() to authenticated;

-- 3 -------------------------------------------------------------------------
alter table public.queues add column if not exists proposed_by uuid;

create or replace function public.stamp_queue_proposer()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.proposed_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists trg_queues_stamp_proposer on public.queues;
create trigger trg_queues_stamp_proposer
  before insert on public.queues
  for each row execute function public.stamp_queue_proposer();

create index if not exists queues_arena_proposed_by_idx
  on public.queues (arena_id, proposed_by);

-- songs has no client SELECT policy, so titles come through a definer RPC
-- scoped to the caller's own proposals.
create or replace function public.get_my_proposals(p_arena_id uuid)
returns table (queue_id uuid, song_id uuid, title text, artist text, queue_type text, created_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  select q.id, s.id, s.title, s.artist, q.queue_type, q.created_at
  from queues q
  join songs s on s.id = q.song_id
  where q.arena_id = p_arena_id
    and q.proposed_by = auth.uid()
    and auth.uid() is not null
  order by q.created_at asc;
$$;

revoke all on function public.get_my_proposals(uuid) from public, anon;
grant execute on function public.get_my_proposals(uuid) to authenticated;
