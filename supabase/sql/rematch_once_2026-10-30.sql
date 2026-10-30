-- ===========================================================================
-- Revancha only once (user decision 2026-10-30, after reading the step-17
-- test log: with the queue empty, "By Design" lost and came back as revancha
-- in battles 9, 11 and 13). A previous loser may return as revancha once: a
-- song that already fought twice in this arena (its first battle + one
-- return, revancha or re-proposed by a human; cancelled battles don't count)
-- is no longer a revancha candidate, so the reserve, lent Liked Songs and
-- member profiles get their turn. Proposing it again by hand is still allowed.
-- ===========================================================================

create or replace function public.pick_rematch_song(
  p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid default null,
  p_partner public.song_feature default null, p_ref public.song_feature default null, p_has_partner boolean default false)
returns uuid
language sql
security definer
set search_path = public
as $$
  select x.id from (
    select s.id, s.isrc, max(b.created_at) as last_fought
    from songs s
    join battles b on b.arena_id = p_arena_id
                  and b.state = 'completed'
                  and b.resolution_type in ('normal', 'sudden_death')
                  and s.id in (b.song_a_id, b.song_b_id)
                  and s.id <> b.winner_song_id
    where s.arena_id = p_arena_id
      and s.role = 'competitor'
      and s.status = 'active'
      and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
      and not exists (select 1 from battles lb where lb.id = p_last_battle and s.id in (lb.song_a_id, lb.song_b_id))
      and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
      and track_available_at(p_arena_id, s.spotify_track_id) is null
      -- Only once (2026-10-30): a song that already fought twice here (its
      -- first battle + one return) never comes back as revancha
      and (select count(*) from battles b2
           where b2.arena_id = p_arena_id and s.id in (b2.song_a_id, b2.song_b_id)
             and b2.resolution_type is distinct from 'cancelled') < 2
      and (p_avoid_proposer is null
           or not exists (select 1 from proposal_history h
                          where h.arena_id = p_arena_id and h.song_id = s.id
                            and h.kind = 'proposal' and h.proposed_by = p_avoid_proposer))
    group by s.id, s.isrc
  ) x
  -- Step 17: the most compatible first, then the oldest loser
  order by floor(matchmaking_song_score(song_features(x.isrc), p_partner, p_ref, p_has_partner)
                 / (select fit_bucket from system_song_config where id = 1)) desc,
           x.last_fought, random()
  limit 1;
$$;

revoke all on function public.pick_rematch_song(uuid, text[], uuid, uuid, public.song_feature, public.song_feature, boolean) from public, anon, authenticated;
