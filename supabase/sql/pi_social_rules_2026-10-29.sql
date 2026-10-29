-- ===========================================================================
-- PI rewards the song, among other people (user decisions 2026-10-29, after
-- the in-app test of step 15). Replaces fair_play_2026-10-29.sql's
-- "≥ 2 explicit voters" rule, which denied a winner's proposer their PI when
-- they didn't vote themselves.
--
-- 1. Win / draw / Sudden Death bonus / backing: PI is for your song winning
--    (your pokémon), not for your vote. Each recipient gets it when at least
--    one person OTHER than them cast an explicit vote in the battle, for
--    either song (votes status 'active', not passive; pre-assigned votes are
--    their backer's). Alone, or with only your own vote, nothing. Backers
--    still need their own counted vote for the song (step 15), plus someone
--    else's vote.
-- 2. +1 for reaching a battle: only with at least pi_config.entry_min_present
--    (2) people present when that battle starts (participant_presence ACTIVO
--    or PASIVO), and never for songs proposed in the lobby (before Start,
--    proposal_history.proposed_at < arenas.started_at).
-- The game rewards people listening to music together.
-- ===========================================================================

alter table public.pi_config drop column if exists min_voters;
alter table public.pi_config add column if not exists entry_min_present integer not null default 2;

create or replace function public.pi_on_battle_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c pi_config;
  v_started timestamptz;
  r record;
begin
  select * into c from pi_config where id;
  -- Alone (or almost): no +1
  if (select count(distinct pp.identity_anchor_id) from participant_presence pp
      where pp.arena_id = new.arena_id and pp.state in ('active', 'passive')) < c.entry_min_present then
    return null;
  end if;
  select started_at into v_started from arenas where id = new.arena_id;

  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled' and h.proposed_by is not null
      -- proposed after Start, not in the lobby
      and v_started is not null and h.proposed_at >= v_started
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'battle_entry', c.battle_entry);
  end loop;
  return null;
end;
$$;

create or replace function public.pi_on_battle_completed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c pi_config;
  v_sd boolean := new.sudden_death_started_at is not null;
  v_songs uuid[];
  v_reason text;
  v_base integer;
  r record;
begin
  if new.resolution_type is null or new.resolution_type not in ('normal', 'sudden_death', 'draw') then
    return null;  -- cancelled: nothing (battle_entry stays)
  end if;
  select * into c from pi_config where id;

  if new.resolution_type = 'draw' then
    v_songs := array[new.song_a_id, new.song_b_id];
    v_reason := 'tie';
    v_base := c.tie;
  else
    if new.winner_song_id is null then
      return null;
    end if;
    v_songs := array[new.winner_song_id];
    v_reason := 'win';
    v_base := c.win;
  end if;

  -- Original proposers (system songs have none), whether or not they voted,
  -- when someone else voted in this battle
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled'
      and h.proposed_by is not null and h.song_id = any (v_songs)
      and exists (select 1 from votes o
                  where o.battle_id = new.id and o.status = 'active' and o.vote_type <> 'passive'
                    and o.identity_anchor_id <> h.proposed_by)
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, v_reason, v_base);
    if v_sd then
      perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'sudden_death_bonus', c.sudden_death_bonus);
    end if;
  end loop;

  -- Backers: pre-assigned at the start, still their counted vote at the end,
  -- and someone else voted too
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'backing' and h.vote_preassigned
      and h.proposed_by is not null and h.song_id = any (v_songs)
      and exists (select 1 from votes v
                  where v.battle_id = new.id and v.identity_anchor_id = h.proposed_by
                    and v.song_id = h.song_id and v.status = 'active' and v.vote_type <> 'passive'
                    and (new.sudden_death_started_at is null or v.vote_type = 'sudden_death'))
      and exists (select 1 from votes o
                  where o.battle_id = new.id and o.status = 'active' and o.vote_type <> 'passive'
                    and o.identity_anchor_id <> h.proposed_by)
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'duplicate_half',
                     round((v_base + case when v_sd then c.sudden_death_bonus else 0 end) * c.backing_share)::integer);
  end loop;

  return null;
end;
$$;
