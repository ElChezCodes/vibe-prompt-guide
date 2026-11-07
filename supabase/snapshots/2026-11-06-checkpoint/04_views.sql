create or replace view public.arena_live_state as
 SELECT g.battle_id,
    g.arena_id,
    g.status,
    g.started_at,
    g.duration_ms,
    g.lockin_at,
    g.resolution_type,
    g.winner_song_id,
    g.battle_created_at,
    g.song_a_id,
    g.song_a_title,
    g.song_a_artist,
    g.song_a_source,
    g.song_a_spotify_track_id,
    g.song_a_duration_ms,
    g.song_b_id,
    g.song_b_title,
    g.song_b_artist,
    g.song_b_source,
    g.song_b_spotify_track_id,
    g.song_b_duration_ms,
    g.votes_a,
    g.votes_b,
    g.sudden_death_active,
    g.song_a_artwork_url,
    g.song_b_artwork_url,
    t.passive_a,
    t.passive_b
   FROM ( SELECT b.id AS battle_id,
            b.arena_id,
            b.state AS status,
            b.started_at,
            b.duration_ms,
            b.lockin_at,
            b.resolution_type,
            b.winner_song_id,
            b.created_at AS battle_created_at,
            sa.id AS song_a_id,
            sa.title AS song_a_title,
            sa.artist AS song_a_artist,
            sa.source AS song_a_source,
            sa.spotify_track_id AS song_a_spotify_track_id,
            sa.duration_ms AS song_a_duration_ms,
            sb.id AS song_b_id,
            sb.title AS song_b_title,
            sb.artist AS song_b_artist,
            sb.source AS song_b_source,
            sb.spotify_track_id AS song_b_spotify_track_id,
            sb.duration_ms AS song_b_duration_ms,
            count(v.id) FILTER (WHERE v.song_id = sa.id AND v.status = 'active'::text AND v.vote_type <> 'passive'::text AND (b.sudden_death_started_at IS NULL OR v.vote_type = 'sudden_death'::text)) AS votes_a,
            count(v.id) FILTER (WHERE v.song_id = sb.id AND v.status = 'active'::text AND v.vote_type <> 'passive'::text AND (b.sudden_death_started_at IS NULL OR v.vote_type = 'sudden_death'::text)) AS votes_b,
            b.sudden_death_active,
            sa.artwork_url AS song_a_artwork_url,
            sb.artwork_url AS song_b_artwork_url
           FROM battles b
             JOIN songs sa ON sa.id = b.song_a_id
             JOIN songs sb ON sb.id = b.song_b_id
             LEFT JOIN votes v ON v.battle_id = b.id
          WHERE b.state = ANY (ARRAY['pending'::text, 'active'::text, 'closing'::text, 'completed'::text])
          GROUP BY b.id, sa.id, sb.id) g
     CROSS JOIN LATERAL battle_passive_tally(g.battle_id) t(passive_a, passive_b);

create or replace view public.participant_presence with (security_invoker=true) as
 SELECT p.id AS participant_id,
    p.arena_id,
    p.identity_anchor_id,
    p.is_host,
    presence_state(p.last_active_at, p.last_seen_at, p.disconnected_at, p.left_at, a.state) AS state,
    p.last_active_at,
    p.last_seen_at
   FROM participants p
     JOIN arenas a ON a.id = p.arena_id;
