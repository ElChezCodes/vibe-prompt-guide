-- ===========================================================================
-- Step 14 review fixes (2026-10-28), on top of duplicate_backing_2026-10-28.sql
--   * back_proposal no longer requires left_at is null: a member who left
--     still proposes like before (the queues insert doesn't check it) and
--     got an error instead of a result; their backing is cast only if they
--     come back (apply_preassigned_votes still skips those who left).
--   * "Vote for it now" (like, proposing a song that is fighting) is one
--     helper, cast_vote_if_none, instead of two copies of the phase rule.
--   * A backing not cast at the start (both songs backed) and then voted
--     by proposing the song while it fights is marked vote_applied.
--   * The backer removing their own backing is outcome 'removed'; 'withdrawn'
--     for a backing now means the original proposer withdrew the song.
-- vote_applied = the pre-assigned vote was cast (at the start, or by
-- proposing the song while it fought); later switches don't change it.
-- ===========================================================================

alter table public.proposal_history drop constraint if exists proposal_history_outcome_check;
alter table public.proposal_history
  add constraint proposal_history_outcome_check check (outcome in ('battled', 'purged', 'withdrawn', 'removed'));

-- The caller's regular vote for p_song_id in the open battle it fights in,
-- if they have no active vote and voting is open (before lock-in, not Sudden
-- Death, arena active and not paused); a cancelled vote is reactivated for
-- this song. Returns the battle voted in, else NULL. Runs as the caller
-- (fill_vote_fields stamps auth.uid()).
create or replace function public.cast_vote_if_none(p_arena_id uuid, p_song_id uuid, p_participant uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_battle battles;
  v_rows int;
begin
  select b.* into v_battle
  from battles b join arenas a on a.id = b.arena_id
  where b.arena_id = p_arena_id and b.state = 'active' and b.lockin_at is null
    and not b.sudden_death_active and a.state = 'active' and a.paused_at is null
    and p_song_id in (b.song_a_id, b.song_b_id)
  order by b.created_at desc
  limit 1;
  if not found or exists (select 1 from votes v where v.battle_id = v_battle.id
                          and v.participant_id = p_participant and v.status = 'active') then
    return null;
  end if;

  insert into votes (battle_id, song_id, participant_id, vote_type, status)
  values (v_battle.id, p_song_id, p_participant, 'regular', 'active')
  on conflict (battle_id, participant_id) do update
    set song_id = excluded.song_id, status = 'active', updated_at = now()
    where votes.status = 'cancelled' and votes.vote_type = 'regular';
  get diagnostics v_rows = row_count;
  return case when v_rows > 0 then v_battle.id end;
end;
$function$;
revoke all on function public.cast_vote_if_none(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.toggle_song_like(p_arena_id uuid, p_song_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_found boolean;
  v_added timestamptz;
  v_voted boolean := false;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select p.id into v_participant
  from participants p join arenas a on a.id = p.arena_id
  where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid
    and p.left_at is null and a.state in ('waiting', 'active');
  if v_participant is null then
    raise exception 'not a member of an open arena' using errcode = '42501';
  end if;
  if not exists (select 1 from songs where id = p_song_id and arena_id = p_arena_id) then
    raise exception 'song not in this arena' using errcode = '22023';
  end if;

  -- A like is an action in the arena (v3.2: any action -> ACTIVO)
  perform touch_participant_activity(p_arena_id, v_uid);

  delete from song_likes where participant_id = v_participant and song_id = p_song_id
  returning true, added_to_spotify_at into v_found, v_added;
  if v_found then
    delete from affinity_signals s
    using songs so
    where so.id = p_song_id and s.user_id = v_uid and s.kind = 'like'
      and s.isrc = so.isrc and s.arena_id = p_arena_id;
    -- Unliking never touches the vote
    return jsonb_build_object('liked', false, 'voted', false, 'remove_from_spotify', v_added is not null);
  end if;

  insert into song_likes (arena_id, song_id, participant_id) values (p_arena_id, p_song_id, v_participant);
  perform record_affinity_signal(v_uid, p_song_id, 'like', p_arena_id);

  -- No active vote in the open battle with this song: the like votes for it
  v_voted := cast_vote_if_none(p_arena_id, p_song_id, v_participant) is not null;

  return jsonb_build_object('liked', true, 'voted', v_voted, 'remove_from_spotify', false);
end;
$function$;

create or replace function public.back_proposal(p_arena_id uuid, p_song_id uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_track text;
  v_battle battles;
  v_song uuid;
  v_vote votes;
  v_rows int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select p.id into v_participant
  from participants p join arenas a on a.id = p.arena_id
  where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid
    and a.state in ('waiting', 'active');
  if v_participant is null then
    raise exception 'not a member of an open arena' using errcode = '42501';
  end if;
  select spotify_track_id into v_track from songs where id = p_song_id and arena_id = p_arena_id;
  if v_track is null then
    raise exception 'song not in this arena' using errcode = '22023';
  end if;

  perform lock_arena_queue(p_arena_id);
  -- Proposing is an action, whatever the answer
  perform touch_participant_activity(p_arena_id, v_uid);

  -- Queued: a pre-assigned vote for its battle, not a new entry
  if exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id) then
    if exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id and proposed_by = v_uid) then
      return 'own_proposal';
    end if;
    if exists (select 1 from queue_backers where arena_id = p_arena_id and song_id = p_song_id and user_id = v_uid) then
      return 'already_backed';
    end if;
    if (select count(*) from queue_backers where arena_id = p_arena_id and user_id = v_uid) >= 5 then
      return 'backing_full';
    end if;
    insert into queue_backers (arena_id, song_id, user_id) values (p_arena_id, p_song_id, v_uid);
    perform record_affinity_signal(v_uid, p_song_id, 'proposal', p_arena_id);
    return 'backed';
  end if;

  -- Fighting now: vote for it at once (same rule as a like)
  select b.* into v_battle
  from battles b join songs s on s.id in (b.song_a_id, b.song_b_id)
  where b.arena_id = p_arena_id and b.state in ('pending', 'active', 'closing')
    and s.spotify_track_id = v_track
  order by b.created_at desc
  limit 1;
  if not found then
    return 'not_queued';
  end if;
  select s.id into v_song from songs s
  where s.id in (v_battle.song_a_id, v_battle.song_b_id) and s.spotify_track_id = v_track
  limit 1;

  select * into v_vote from votes
  where battle_id = v_battle.id and participant_id = v_participant and status = 'active';
  if found then
    return case when v_vote.song_id = v_song then 'already_voted' else 'in_battle' end;
  end if;
  if cast_vote_if_none(p_arena_id, v_song, v_participant) is distinct from v_battle.id then
    return 'in_battle';
  end if;

  -- Step 15: a duplicate of someone else's proposal fighting now (a backing
  -- of it that wasn't cast at the start, e.g. both songs backed, is now)
  update proposal_history set vote_applied = true
  where battle_id = v_battle.id and song_id = v_song and kind = 'backing' and proposed_by = v_uid;
  get diagnostics v_rows = row_count;
  if v_rows = 0 and exists (select 1 from proposal_history h
                            where h.battle_id = v_battle.id and h.song_id = v_song
                              and h.kind = 'proposal' and h.proposed_by <> v_uid) then
    insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, battle_id, kind, vote_applied)
    values (p_arena_id, v_song, v_uid, now(), 'battled', v_battle.id, 'backing', true);
  end if;
  return 'voted';
end;
$function$;

create or replace function public.withdraw_backing(p_arena_id uuid, p_song_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_rows int;
begin
  if auth.uid() is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from arenas where id = p_arena_id and state in ('waiting', 'active')) then
    raise exception 'arena_closed' using errcode = '55000';
  end if;

  perform lock_arena_queue(p_arena_id);

  -- Under the lock: its battle may have just started (then it is a vote)
  with gone as (
    delete from queue_backers
    where arena_id = p_arena_id and song_id = p_song_id and user_id = auth.uid()
    returning *
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, kind)
  select arena_id, song_id, user_id, created_at, 'removed', 'backing' from gone;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform touch_participant_activity(p_arena_id, auth.uid());
end;
$function$;
