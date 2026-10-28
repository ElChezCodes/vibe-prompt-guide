-- ===========================================================================
-- Likes, follow-up to steps 8+9 (user decisions 2026-10-27):
--   * A like on a song of the open battle casts a regular vote for it when the
--     liker has no active vote (none, or a cancelled one: liking is a new
--     action), only during normal voting (before lock-in, arena not paused).
--     Never a Sudden Death vote. Voting for the other song later changes the
--     vote, not the like; both songs of a battle can be liked.
--   * The like is also saved to the liker's OWN Spotify Liked Songs when they
--     have connected Spotify with user-library-modify (spotify-host action
--     "like"; soft re-consent for older connections). MF only adds it if it
--     wasn't already there, and unliking only removes it from Spotify when MF
--     added it (song_likes.added_to_spotify_at).
-- ===========================================================================

alter table public.song_likes add column if not exists added_to_spotify_at timestamptz;

drop function if exists public.toggle_song_like(uuid, uuid);

-- { liked, voted, remove_from_spotify }
create or replace function public.toggle_song_like(p_arena_id uuid, p_song_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_found boolean;
  v_added timestamptz;
  v_battle battles;
  v_voted boolean := false;
  v_rows int;
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

  -- No active vote in the open battle with this song, normal voting phase:
  -- the like votes for it (a cancelled vote is reactivated for this song)
  select b.* into v_battle
  from battles b join arenas a on a.id = b.arena_id
  where b.arena_id = p_arena_id and b.state = 'active' and b.lockin_at is null
    and not b.sudden_death_active and a.state = 'active' and a.paused_at is null
    and p_song_id in (b.song_a_id, b.song_b_id)
  order by b.created_at desc
  limit 1;
  if found and not exists (select 1 from votes v where v.battle_id = v_battle.id
                           and v.participant_id = v_participant and v.status = 'active') then
    insert into votes (battle_id, song_id, participant_id, vote_type, status)
    values (v_battle.id, p_song_id, v_participant, 'regular', 'active')
    on conflict (battle_id, participant_id) do update
      set song_id = excluded.song_id, status = 'active', updated_at = now()
      where votes.status = 'cancelled' and votes.vote_type = 'regular';
    get diagnostics v_rows = row_count;
    v_voted := v_rows > 0;
  end if;

  return jsonb_build_object('liked', true, 'voted', v_voted, 'remove_from_spotify', false);
end;
$$;
revoke all on function public.toggle_song_like(uuid, uuid) from public, anon;
grant execute on function public.toggle_song_like(uuid, uuid) to authenticated;

-- spotify-host, after saving the track to the liker's Spotify Liked Songs
create or replace function public.mark_like_saved_to_spotify(p_user uuid, p_arena_id uuid, p_song_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update song_likes l set added_to_spotify_at = now()
  from participants p
  where p.id = l.participant_id and p.identity_anchor_id = p_user
    and l.arena_id = p_arena_id and l.song_id = p_song_id;
$$;
revoke all on function public.mark_like_saved_to_spotify(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.mark_like_saved_to_spotify(uuid, uuid, uuid) to service_role;
