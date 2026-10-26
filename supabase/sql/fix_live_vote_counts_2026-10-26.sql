-- Fix arena_live_state vote counts including cancelled votes, 2026-10-26
--
-- votes_a / votes_b counted every vote row for the song, so a vote toggled
-- off (status = 'cancelled') kept counting in the tension bar / on-screen
-- tallies. Display-only bug: the tallies that decide winners already filter
-- status = 'active' (calculate_lockin_vote_totals for lock-in, the inline
-- sudden_death tally in process_battle_lifecycle) -- verified against the
-- live definitions, so no past result was decided wrongly.
--
-- Same columns, order and types as the live view; only the FILTER changes.
-- No reloptions and no dependent views; CREATE OR REPLACE keeps grants.

create or replace view public.arena_live_state as
select
  b.id as battle_id,
  b.arena_id,
  b.state as status,
  b.started_at,
  b.duration_ms,
  b.lockin_at,
  b.resolution_type,
  b.winner_song_id,
  b.created_at as battle_created_at,
  sa.id as song_a_id,
  sa.title as song_a_title,
  sa.artist as song_a_artist,
  sa.source as song_a_source,
  sa.spotify_track_id as song_a_spotify_track_id,
  sa.duration_ms as song_a_duration_ms,
  sb.id as song_b_id,
  sb.title as song_b_title,
  sb.artist as song_b_artist,
  sb.source as song_b_source,
  sb.spotify_track_id as song_b_spotify_track_id,
  sb.duration_ms as song_b_duration_ms,
  count(v.id) filter (where v.song_id = sa.id and v.status = 'active') as votes_a,
  count(v.id) filter (where v.song_id = sb.id and v.status = 'active') as votes_b
from battles b
  join songs sa on sa.id = b.song_a_id
  join songs sb on sb.id = b.song_b_id
  left join votes v on v.battle_id = b.id
where b.state = any (array['pending', 'active', 'closing', 'completed'])
group by b.id, sa.id, sb.id;
