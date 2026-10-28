-- "Your proposals" shows each song as a Spotify row (artwork, logo, "Open
-- Spotify" link): get_my_proposals also returns spotify_track_id (2026-10-27).
-- Otherwise identical to queue_rules_2026-10-27.sql.

drop function if exists public.get_my_proposals(uuid);
create function public.get_my_proposals(p_arena_id uuid)
returns table (
  queue_id uuid, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text,
  status text, place bigint, battles_left integer, at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select x.queue_id, x.song_id, x.spotify_track_id, x.title, x.artist, x.artwork_url, x.status, x.place, x.battles_left, x.at
  from (
    select r.id as queue_id, s.id as song_id, s.spotify_track_id, s.title, s.artist, s.artwork_url,
           case r.queue_type when 'active' then 'next' else 'waiting' end as status,
           r.rank_in_list as place,
           case when r.queue_type = 'waiting' then 20 - r.battles_waited end as battles_left,
           r.created_at as at,
           0 as grp, r.global_rank as k
    from queue_ranked(p_arena_id) r
    join songs s on s.id = r.song_id
    where r.proposed_by = auth.uid() and auth.uid() is not null
    union all
    select null, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url,
           case
             when h.outcome <> 'battled' then h.outcome
             when b.resolution_type = 'cancelled' then 'cancelled'
             when b.resolution_type = 'draw' then 'draw'
             when b.winner_song_id = h.song_id then 'won'
             when b.winner_song_id is not null then 'lost'
             else 'competing'
           end,
           null, null, h.ended_at,
           1, -extract(epoch from h.ended_at)::bigint
    from proposal_history h
    join songs s on s.id = h.song_id
    left join battles b on b.id = h.battle_id
    where h.arena_id = p_arena_id and h.proposed_by = auth.uid() and auth.uid() is not null
  ) x
  order by x.grp, x.k;
$$;

revoke execute on function public.get_my_proposals(uuid) from public, anon;
grant execute on function public.get_my_proposals(uuid) to authenticated;
