-- Song rotation: participant-proposed + like-driven queue, feeding
-- process_battle_lifecycle instead of it repeating the same two songs forever.
-- Implemented 2026-10-26. battle_lifecycle_job was disabled while this was built.

-- ============================================================
-- 1. song_likes
-- ============================================================

create table if not exists song_likes (
  id uuid primary key default gen_random_uuid(),
  arena_id uuid not null references arenas(id) on delete cascade,
  song_id uuid not null references songs(id) on delete cascade,
  participant_id uuid not null references participants(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint song_likes_unique unique (arena_id, song_id, participant_id)
);

alter table song_likes enable row level security;

-- Participant_id is never trusted from the client: derived here from
-- participants (identity_anchor_id = auth.uid(), scoped to the arena being
-- liked into), same spirit as fill_vote_fields forcing identity_anchor_id on
-- votes -- but via a real relational lookup rather than assuming
-- participant_id == auth.uid() (see report: votes' own RLS does the latter,
-- which looks like a pre-existing inconsistency, left untouched, out of scope).
create or replace function fill_song_like_fields()
returns trigger
language plpgsql
as $$
declare
  v_participant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'auth.uid() is required to like a song';
  end if;

  select id into v_participant_id
  from participants
  where identity_anchor_id = auth.uid()
    and arena_id = new.arena_id;

  if v_participant_id is null then
    raise exception 'no participant found for this user in this arena';
  end if;

  new.participant_id := v_participant_id;
  return new;
end;
$$;

create trigger trg_fill_song_like_fields
before insert on song_likes
for each row execute function fill_song_like_fields();

create policy song_likes_insert_self on song_likes
  for insert
  with check (auth.uid() is not null);

create policy song_likes_delete_self on song_likes
  for delete
  using (exists (
    select 1 from participants p
    where p.id = song_likes.participant_id
      and p.identity_anchor_id = auth.uid()
  ));

create policy song_likes_select_arena on song_likes
  for select
  using (exists (
    select 1 from participants p
    where p.arena_id = song_likes.arena_id
      and p.identity_anchor_id = auth.uid()
  ));

-- ============================================================
-- 2. queues: fix garbage default, add real constraints + RLS
-- ============================================================

alter table queues alter column queue_type set default 'waiting';
alter table queues add constraint queues_queue_type_check
  check (queue_type in ('waiting','active'));
alter table queues add constraint queues_arena_song_unique
  unique (arena_id, song_id);

alter table queues enable row level security;

-- Explicit proposals (ProposeSongModal): a participant can insert a waiting
-- entry for a song into their own arena's queue.
create policy queues_insert_proposal on queues
  for insert
  with check (
    queue_type = 'waiting'
    and exists (
      select 1 from participants p
      where p.arena_id = queues.arena_id
        and p.identity_anchor_id = auth.uid()
    )
  );

create policy queues_select_arena on queues
  for select
  using (exists (
    select 1 from participants p
    where p.arena_id = queues.arena_id
      and p.identity_anchor_id = auth.uid()
  ));

-- No client UPDATE/DELETE policy: promotion/consumption only happens via
-- SECURITY DEFINER functions below (service role / cron), matching the same
-- backend-authoritative pattern already used for battles.state.

-- ============================================================
-- 3. Like threshold -> auto-queue (trigger on song_likes insert)
-- ============================================================

create or replace function promote_liked_song_to_queue()
returns trigger
language plpgsql
security definer
as $$
declare
  v_like_count integer;
  v_next_position integer;
begin
  select count(*) into v_like_count
  from song_likes
  where arena_id = new.arena_id
    and song_id = new.song_id;

  if v_like_count < 3 then
    return new;
  end if;

  if exists (
    select 1 from queues
    where arena_id = new.arena_id and song_id = new.song_id
  ) then
    -- Already queued (explicit proposal or earlier threshold crossing) --
    -- let accumulating likes keep bumping its priority so popular songs
    -- promote to active first.
    update queues
    set priority = v_like_count, updated_at = now()
    where arena_id = new.arena_id and song_id = new.song_id;
    return new;
  end if;

  select coalesce(max(position), 0) + 1 into v_next_position
  from queues where arena_id = new.arena_id;

  insert into queues (arena_id, song_id, queue_type, position, priority)
  values (new.arena_id, new.song_id, 'waiting', v_next_position, v_like_count);

  return new;
end;
$$;

create trigger trg_promote_liked_song_to_queue
after insert on song_likes
for each row execute function promote_liked_song_to_queue();

-- ============================================================
-- 4. Queue pull: promote waiting->active (cap 10), return next 2 songs
-- ============================================================

create or replace function pull_next_battle_songs(p_arena_id uuid)
returns table(song_a uuid, song_b uuid)
language plpgsql
security definer
as $$
declare
  v_active_count integer;
  v_promote_slots integer;
begin
  select count(*) into v_active_count
  from queues where arena_id = p_arena_id and queue_type = 'active';

  if v_active_count < 2 then
    v_promote_slots := 10 - v_active_count;

    update queues
    set queue_type = 'active', updated_at = now()
    where id in (
      select id from queues
      where arena_id = p_arena_id and queue_type = 'waiting'
      order by priority desc, created_at asc
      limit v_promote_slots
    );
  end if;

  return query
  with picked as (
    select id, song_id,
           row_number() over (order by priority desc, created_at asc) as rn
    from queues
    where arena_id = p_arena_id and queue_type = 'active'
    order by priority desc, created_at asc
    limit 2
  ),
  deleted as (
    delete from queues where id in (select id from picked)
    returning 1
  )
  select
    (select song_id from picked where rn = 1),
    (select song_id from picked where rn = 2)
  where (select count(*) from picked) = 2;
  -- returns zero rows if fewer than 2 were available -- caller falls back
end;
$$;

-- ============================================================
-- 5. process_battle_lifecycle: pull from queue instead of repeating itself
-- ============================================================
-- Surgical change: only the final "next battle" INSERT block changes.
-- Everything else (lock-in timing, Sudden Death, draw handling,
-- playlist_queue writes) is byte-for-byte identical to the live version.

create or replace function public.process_battle_lifecycle(p_arena_id uuid)
returns void
language plpgsql
as $function$
DECLARE
    v_battle RECORD;
    v_now timestamptz := now();
    v_lockin_at timestamptz;
    v_end_at timestamptz;

    v_votes RECORD;
    v_next_duration integer;
    v_winner uuid;

    v_next_songs RECORD;
    v_next_song_a uuid;
    v_next_song_b uuid;
BEGIN

    -- 1️⃣ Obtener battle viva y lockearla
    SELECT *
    INTO v_battle
    FROM battles
    WHERE arena_id = p_arena_id
      AND state IN ('pending','active','closing')
    ORDER BY created_at
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- 2️⃣ pending → active
    IF v_battle.state = 'pending' THEN
        UPDATE battles
        SET state = 'active',
            started_at = v_now
        WHERE id = v_battle.id;
        RETURN;
    END IF;

    -- Calcular tiempos deterministas
    v_lockin_at :=
        v_battle.started_at
        + ((v_battle.duration_ms - 15000) * interval '1 millisecond');

    v_end_at :=
        v_battle.started_at
        + (v_battle.duration_ms * interval '1 millisecond');

    -- 3️⃣ ACTIVE → CLOSING (LOCK-IN)
    IF v_battle.state = 'active'
       AND v_now >= v_lockin_at
    THEN

        SELECT *
        INTO v_votes
        FROM calculate_lockin_vote_totals(v_battle.id);

        IF v_votes.is_tie = false THEN

            v_winner := CASE
                WHEN v_votes.votes_a > v_votes.votes_b THEN v_battle.song_a_id
                ELSE v_battle.song_b_id
            END;

            INSERT INTO playlist_queue (
                arena_id,
                battle_id,
                winner_song_id,
                spotify_track_id,
                song_duration_ms,
                created_at
            )
            SELECT
                v_battle.arena_id,
                v_battle.id,
                s.id,
                s.spotify_track_id,
                s.duration_ms,
                v_now
            FROM songs s
            WHERE s.id = v_winner;

            UPDATE battles
            SET state = 'closing',
                lockin_at = v_lockin_at,
                winner_song_id = v_winner,
                resolution_type = 'normal'
            WHERE id = v_battle.id;

        ELSE
            UPDATE battles
            SET state = 'closing',
                lockin_at = v_lockin_at,
                sudden_death_active = true,
                sudden_death_started_at = v_lockin_at
            WHERE id = v_battle.id;
        END IF;

        RETURN;
    END IF;

    -- 4️⃣ END OF BATTLE
    IF v_battle.state = 'closing'
       AND v_now >= v_end_at
    THEN

        -- Releer estado real antes de resolver
        SELECT *
        INTO v_battle
        FROM battles
        WHERE id = v_battle.id
        FOR UPDATE;

        -- Resolver Sudden Death si estaba activo
        IF v_battle.sudden_death_active = true THEN

            SELECT
                COALESCE(SUM(weight) FILTER (
                    WHERE song_id = v_battle.song_a_id
                    AND vote_type = 'sudden_death'
                    AND status = 'active'
                ),0) AS votes_a,
                COALESCE(SUM(weight) FILTER (
                    WHERE song_id = v_battle.song_b_id
                    AND vote_type = 'sudden_death'
                    AND status = 'active'
                ),0) AS votes_b
            INTO v_votes
            FROM votes
            WHERE battle_id = v_battle.id;

            IF v_votes.votes_a <> v_votes.votes_b THEN

                v_winner := CASE
                    WHEN v_votes.votes_a > v_votes.votes_b THEN v_battle.song_a_id
                    ELSE v_battle.song_b_id
                END;

                INSERT INTO playlist_queue (
                    arena_id,
                    battle_id,
                    winner_song_id,
                    spotify_track_id,
                    song_duration_ms,
                    created_at
                )
                SELECT
                    v_battle.arena_id,
                    v_battle.id,
                    s.id,
                    s.spotify_track_id,
                    s.duration_ms,
                    v_now
                FROM songs s
                WHERE s.id = v_winner;

                UPDATE battles
                SET winner_song_id = v_winner,
                    resolution_type = 'sudden_death',
                    sudden_death_active = false
                WHERE id = v_battle.id;

            ELSE
                -- SD empate real (0-0 o X-X) → DRAW
                INSERT INTO playlist_queue (
                    arena_id,
                    battle_id,
                    winner_song_id,
                    spotify_track_id,
                    song_duration_ms,
                    created_at
                )
                SELECT
                    v_battle.arena_id,
                    v_battle.id,
                    s.id,
                    s.spotify_track_id,
                    s.duration_ms,
                    v_now
                FROM songs s
                WHERE s.id IN (v_battle.song_a_id, v_battle.song_b_id);

                UPDATE battles
                SET resolution_type = 'draw',
                    sudden_death_active = false
                WHERE id = v_battle.id;
            END IF;
        END IF;

        -- Garantizar resolución antes de completar
        SELECT resolution_type
        INTO v_votes
        FROM battles
        WHERE id = v_battle.id;

        IF v_votes.resolution_type IS NULL THEN
            RETURN; -- no completar si no hay resolución válida
        END IF;

        -- Cierre final
        UPDATE battles
        SET state = 'completed',
            ended_at = v_end_at,
            enqueue_done = true
        WHERE id = v_battle.id;

        -- Duración siguiente battle
        SELECT SUM(song_duration_ms)
        INTO v_next_duration
        FROM playlist_queue
        WHERE battle_id = v_battle.id;

        -- 🔁 Próximas canciones: tirar de la cola (propuestas/likes) en vez
        -- de repetir siempre las mismas dos. Si la cola no tiene suficientes
        -- canciones disponibles, se cae al comportamiento anterior.
        SELECT * INTO v_next_songs FROM pull_next_battle_songs(v_battle.arena_id);

        IF v_next_songs.song_a IS NOT NULL AND v_next_songs.song_b IS NOT NULL THEN
            v_next_song_a := v_next_songs.song_a;
            v_next_song_b := v_next_songs.song_b;
        ELSE
            v_next_song_a := v_battle.song_a_id;
            v_next_song_b := v_battle.song_b_id;
        END IF;

        INSERT INTO battles (
            arena_id,
            song_a_id,
            song_b_id,
            state,
            duration_ms,
            created_at
        )
        VALUES (
            v_battle.arena_id,
            v_next_song_a,
            v_next_song_b,
            'pending',
            v_next_duration,
            v_now
        );

        RETURN;
    END IF;

END;
$function$;
