-- Legacy battle-lifecycle pathway -- DEAD CODE, backed up before DROP
--
-- Confirmed dead as of 2026-10-25: nothing in src/ imports or calls any of these,
-- and nothing in cron.job schedules run_battle_closure_job or run_battle_finalizer_job
-- (pg_net is installed but unused by any cron job). The live battle lifecycle runs
-- entirely through process_battle_lifecycle(arena_id), a separate, self-contained
-- reimplementation invoked by the battle_lifecycle_job pg_cron job.
--
-- This was the pre-process_battle_lifecycle implementation: orchestrate_battle_closure
-- was the entry point, calling end_battle (active->closing), resolve_lockin_and_activate_sd
-- (tally regular votes, activate Sudden Death on a tie), resolve_battle_after_sudden_death
-- (tally sudden_death votes), finalize_battle (final winner/draw resolution), and
-- finalize_and_enqueue_battle (insert winner(s) into playlist_queue). Meant to be driven
-- by run_battle_closure_job / run_battle_finalizer_job, which the battle-finalizer-cron
-- Edge Function calls via RPC -- but nothing ever scheduled that Edge Function.
--
-- Kept here for reference/reversibility. To restore, run these CREATE OR REPLACE
-- FUNCTION statements directly against the database.

CREATE OR REPLACE FUNCTION public.end_battle(p_battle_id uuid)
 RETURNS battles
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  updated_battle battles;
begin
  -- Fetch current battle state
  select * into updated_battle
  from battles
  where id = p_battle_id;

  if not found then
    raise exception 'Battle not found';
  end if;

  -- If battle is no longer active, return as-is (tolerant / idempotent)
  if updated_battle.state != 'active' then
    return updated_battle;
  end if;

  -- Transition active → closing
  update battles
  set
    state = 'closing',
    ended_at = now(),
    updated_at = now()
  where id = p_battle_id
    and state = 'active'
  returning * into updated_battle;

  return updated_battle;
end;
$function$

CREATE OR REPLACE FUNCTION public.orchestrate_battle_closure(p_battle_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_state text;
  v_sudden_death_active boolean;
  v_sd_result record;
BEGIN
  -- 1️⃣ Lock autoritativo y lectura de estado actual
  SELECT state, sudden_death_active
  INTO v_state, v_sudden_death_active
  FROM battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Battle % not found', p_battle_id;
  END IF;

  -- 2️⃣ Solo battles activas o en closing son elegibles
  IF v_state NOT IN ('active', 'closing') THEN
    RETURN;
  END IF;

  -- 3️⃣ active → closing
  IF v_state = 'active' THEN
    PERFORM end_battle(p_battle_id);
  END IF;

  -- 4️⃣ Lock-in + resolución de votos regulares
  PERFORM resolve_lockin_and_activate_sd(p_battle_id);

  -- 5️⃣ Releer estado de Sudden Death tras lock-in
  SELECT sudden_death_active
  INTO v_sudden_death_active
  FROM battles
  WHERE id = p_battle_id;

  -- 6️⃣ Si hay Sudden Death activo, evaluarlo
  IF v_sudden_death_active = true THEN
    SELECT *
    INTO v_sd_result
    FROM resolve_battle_after_sudden_death(p_battle_id);

    -- 🔑 CAMBIO CLAVE:
    -- Si hay empate en Sudden Death, NO se retorna.
    -- El empate es un DRAW válido y debe cerrarse.
    -- Se continúa hacia finalize_battle.
  END IF;

  -- 7️⃣ Cierre final SIEMPRE
  -- - ganador normal
  -- - ganador por SD
  -- - DRAW (incluido SD empate / 0 vs 0)
  PERFORM finalize_battle(p_battle_id);

END;
$function$

CREATE OR REPLACE FUNCTION public.resolve_lockin_and_activate_sd(p_battle_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_song_a_id uuid;
  v_song_b_id uuid;
  v_votes_a double precision := 0;
  v_votes_b double precision := 0;
  v_is_tie boolean;
BEGIN
  -- 1️⃣ Garantizar lock-in
  UPDATE battles
  SET lockin_at = COALESCE(lockin_at, now())
  WHERE id = p_battle_id;

  -- 2️⃣ Leer datos base (lock autoritativo implícito por transacción externa)
  SELECT
    song_a_id,
    song_b_id
  INTO
    v_song_a_id,
    v_song_b_id
  FROM battles
  WHERE id = p_battle_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Battle % not found', p_battle_id;
  END IF;

  IF v_song_a_id IS NULL OR v_song_b_id IS NULL THEN
    RAISE EXCEPTION 'Battle % missing song_a_id or song_b_id', p_battle_id;
  END IF;

  -- 3️⃣ Contar votos REGULARES
  SELECT COALESCE(SUM(weight), 0)
  INTO v_votes_a
  FROM votes
  WHERE battle_id = p_battle_id
    AND song_id = v_song_a_id
    AND vote_type = 'regular'
    AND status = 'active';

  SELECT COALESCE(SUM(weight), 0)
  INTO v_votes_b
  FROM votes
  WHERE battle_id = p_battle_id
    AND song_id = v_song_b_id
    AND vote_type = 'regular'
    AND status = 'active';

  v_is_tie := (v_votes_a = v_votes_b);

  -- 4️⃣ Empate → activar Sudden Death
  IF v_is_tie THEN
    UPDATE battles
    SET
      sudden_death_active = true,
      winner_song_id = NULL
    WHERE id = p_battle_id;

    RETURN;
  END IF;

  -- 5️⃣ Ganador claro → escribir winner
  UPDATE battles
  SET
    winner_song_id = CASE
      WHEN v_votes_a > v_votes_b THEN v_song_a_id
      ELSE v_song_b_id
    END,
    sudden_death_active = false
  WHERE id = p_battle_id;
END;
$function$

CREATE OR REPLACE FUNCTION public.resolve_battle_after_sudden_death(p_battle_id uuid)
 RETURNS TABLE(battle_id uuid, votes_a double precision, votes_b double precision, is_tie boolean, winner_song_id uuid, sudden_death_active boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_song_a_id uuid;
  v_song_b_id uuid;
  v_votes_a double precision := 0;
  v_votes_b double precision := 0;
BEGIN
  SELECT song_a_id, song_b_id
  INTO v_song_a_id, v_song_b_id
  FROM battles
  WHERE id = p_battle_id;

  SELECT COALESCE(SUM(v.weight), 0)
  INTO v_votes_a
  FROM votes v
  WHERE v.battle_id = p_battle_id
    AND v.song_id = v_song_a_id
    AND v.vote_type = 'sudden_death'
    AND v.status = 'active';

  SELECT COALESCE(SUM(v.weight), 0)
  INTO v_votes_b
  FROM votes v
  WHERE v.battle_id = p_battle_id
    AND v.song_id = v_song_b_id
    AND v.vote_type = 'sudden_death'
    AND v.status = 'active';

  IF v_votes_a = v_votes_b THEN
    RETURN QUERY
    SELECT
      p_battle_id,
      0::double precision,
      0::double precision,
      true,
      NULL::uuid,
      true;
    RETURN;
  END IF;

  UPDATE battles
  SET
    winner_song_id = CASE
      WHEN v_votes_a > v_votes_b THEN v_song_a_id
      ELSE v_song_b_id
    END,
    sudden_death_active = false
  WHERE id = p_battle_id;

  RETURN QUERY
  SELECT
    p_battle_id,
    v_votes_a,
    v_votes_b,
    false,
    winner_song_id,
    sudden_death_active
  FROM battles
  WHERE id = p_battle_id;
END;
$function$

CREATE OR REPLACE FUNCTION public.finalize_battle(p_battle_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_song_a_id uuid;
  v_song_b_id uuid;
  v_votes_a double precision := 0;
  v_votes_b double precision := 0;

  v_resolution_type text;
  v_winner_song_id uuid;
BEGIN
  -- 1️⃣ Leer battle base (lock autoritativo)
  SELECT song_a_id, song_b_id
  INTO v_song_a_id, v_song_b_id
  FROM battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Battle % not found', p_battle_id;
  END IF;

  -- 2️⃣ Contar TODOS los votos activos (regular + sudden death)
  SELECT COALESCE(SUM(weight), 0)
  INTO v_votes_a
  FROM votes
  WHERE battle_id = p_battle_id
    AND song_id = v_song_a_id
    AND status = 'active';

  SELECT COALESCE(SUM(weight), 0)
  INTO v_votes_b
  FROM votes
  WHERE battle_id = p_battle_id
    AND song_id = v_song_b_id
    AND status = 'active';

  -- 3️⃣ Empate real → DRAW
  IF v_votes_a = v_votes_b THEN
    v_resolution_type := 'draw';
    v_winner_song_id := NULL;

  -- 4️⃣ Ganador claro
  ELSE
    v_winner_song_id :=
      CASE
        WHEN v_votes_a > v_votes_b THEN v_song_a_id
        ELSE v_song_b_id
      END;

    -- ¿hubo sudden death?
    IF EXISTS (
      SELECT 1
      FROM votes
      WHERE battle_id = p_battle_id
        AND vote_type = 'sudden_death'
        AND status = 'active'
    ) THEN
      v_resolution_type := 'sudden_death';
    ELSE
      v_resolution_type := 'normal';
    END IF;
  END IF;

  -- 5️⃣ Persistir cierre FINAL (constraint-safe)
  UPDATE battles
  SET
    resolution_type = v_resolution_type,
    winner_song_id  = v_winner_song_id,
    sudden_death_active = false,
    state = 'completed',
    ended_at = now()
  WHERE id = p_battle_id;

END;
$function$

CREATE OR REPLACE FUNCTION public.finalize_and_enqueue_battle(p_battle_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_state text;
  v_enqueue_done boolean;
  v_resolution_type text;

  v_song_a_id uuid;
  v_song_b_id uuid;
  v_winner_song_id uuid;
  v_arena_id uuid;

  v_spotify_track_id text;
  v_song_duration_ms integer;
BEGIN
  -- 1️⃣ Lock autoritativo
  SELECT
    state,
    enqueue_done,
    resolution_type,
    song_a_id,
    song_b_id,
    winner_song_id,
    arena_id
  INTO
    v_state,
    v_enqueue_done,
    v_resolution_type,
    v_song_a_id,
    v_song_b_id,
    v_winner_song_id,
    v_arena_id
  FROM battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Battle % not found', p_battle_id;
  END IF;

  -- 2️⃣ Idempotencia dura
  IF v_enqueue_done = true THEN
    RETURN;
  END IF;

  -- 3️⃣ Battle DEBE estar finalizada
  IF v_state <> 'completed' THEN
    RAISE EXCEPTION 'Battle % is not completed (state=%)', p_battle_id, v_state;
  END IF;

  IF v_resolution_type IS NULL THEN
    RAISE EXCEPTION 'Battle % has NULL resolution_type', p_battle_id;
  END IF;

  -- 4️⃣ DRAW → encolar ambas canciones
  IF v_resolution_type = 'draw' THEN
    IF v_song_a_id IS NULL OR v_song_b_id IS NULL THEN
      RAISE EXCEPTION 'Draw battle % missing song ids', p_battle_id;
    END IF;

    -- Song A
    SELECT spotify_track_id, duration_ms
    INTO v_spotify_track_id, v_song_duration_ms
    FROM songs
    WHERE id = v_song_a_id;

    IF v_spotify_track_id IS NULL THEN
      RAISE EXCEPTION 'spotify_track_id NULL for song %', v_song_a_id;
    END IF;

    INSERT INTO playlist_queue (
      arena_id,
      battle_id,
      winner_song_id,
      spotify_track_id,
      song_duration_ms
    )
    VALUES (
      v_arena_id,
      p_battle_id,
      v_song_a_id,
      v_spotify_track_id,
      v_song_duration_ms
    );

    -- Song B
    SELECT spotify_track_id, duration_ms
    INTO v_spotify_track_id, v_song_duration_ms
    FROM songs
    WHERE id = v_song_b_id;

    IF v_spotify_track_id IS NULL THEN
      RAISE EXCEPTION 'spotify_track_id NULL for song %', v_song_b_id;
    END IF;

    INSERT INTO playlist_queue (
      arena_id,
      battle_id,
      winner_song_id,
      spotify_track_id,
      song_duration_ms
    )
    VALUES (
      v_arena_id,
      p_battle_id,
      v_song_b_id,
      v_spotify_track_id,
      v_song_duration_ms
    );

  -- 5️⃣ WIN → una sola canción
  ELSE
    IF v_winner_song_id IS NULL THEN
      RAISE EXCEPTION 'Win battle % has NULL winner_song_id', p_battle_id;
    END IF;

    SELECT spotify_track_id, duration_ms
    INTO v_spotify_track_id, v_song_duration_ms
    FROM songs
    WHERE id = v_winner_song_id;

    IF v_spotify_track_id IS NULL THEN
      RAISE EXCEPTION 'spotify_track_id NULL for song %', v_winner_song_id;
    END IF;

    INSERT INTO playlist_queue (
      arena_id,
      battle_id,
      winner_song_id,
      spotify_track_id,
      song_duration_ms
    )
    VALUES (
      v_arena_id,
      p_battle_id,
      v_winner_song_id,
      v_spotify_track_id,
      v_song_duration_ms
    );
  END IF;

  -- 6️⃣ Marcar como procesada
  UPDATE battles
  SET
    enqueue_done = true,
    post_battle_processed_at = now()
  WHERE id = p_battle_id;

END;
$function$

CREATE OR REPLACE FUNCTION public.run_battle_closure_job()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM orchestrate_battle_closure(id)
  FROM battles
  WHERE state = 'active'
    AND started_at IS NOT NULL
    AND duration_ms IS NOT NULL
    AND NOW() >= started_at + (duration_ms * INTERVAL '1 millisecond');
END;
$function$

CREATE OR REPLACE FUNCTION public.run_battle_finalizer_job()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  r record;
BEGIN
  -- 1️⃣ Despertar decisiones de cierre
  -- (lock-in / resolución / finalize si corresponde)
  FOR r IN
    SELECT id
    FROM battles
    WHERE state = 'active'
      AND now() >= (
        started_at
        + (duration_ms * interval '1 millisecond')
        - interval '15 seconds'
      )
  LOOP
    PERFORM orchestrate_battle_closure(r.id);
  END LOOP;

  -- 2️⃣ Enqueue SOLO battles realmente finalizadas
  -- (protección contra resolution_type NULL)
  FOR r IN
    SELECT id
    FROM battles
    WHERE state = 'completed'
      AND enqueue_done = false
      AND resolution_type IS NOT NULL
  LOOP
    PERFORM finalize_and_enqueue_battle(r.id);
  END LOOP;
END;
$function$

