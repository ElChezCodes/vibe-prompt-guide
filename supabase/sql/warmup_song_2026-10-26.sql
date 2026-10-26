-- Warm-up song (roadmap step 2), applied 2026-10-26.
--
-- Spec: Backend_Block_2 §3, Block_3 §1, Block_5 §2.1 -- with a user decision
-- (2026-10-26) that OVERRIDES Block_2 §4 / Block_4 §2 ("warm-up always ends
-- before the first battle"):
--   - The host picks the warm-up while creating the arena (suggestions follow
--     the arena mood). Picking it does not play it; the lobby is silent.
--   - On Start Battles the warm-up starts playing and does NOT stop: it is the
--     first song of the session ("winner of battle 0"), so battle 1 lasts
--     exactly the warm-up's duration -- the same rule process_battle_lifecycle
--     already applies to every later battle (duration = previous winner).
--   - It never competes, is voted, scores, or enters a queue. The same library
--     track can still be proposed: only the arena's role = 'warmup' copy is
--     excluded.
-- Until Spotify (steps 5/6/18) the host's Battle Room browser is the
-- provisional "cantante", playing the curated-songs MP3 via a signed URL.

-- ============================================================
-- 1. Schema
-- ============================================================

alter table songs add column if not exists role text not null default 'competitor';
alter table songs drop constraint if exists songs_role_check;
alter table songs add constraint songs_role_check check (role in ('competitor', 'warmup'));

-- Same vocabulary as arenas_mood_check. Only used for warm-up suggestions and
-- the first-battle fallback; MVP-only tagging of the curated library.
alter table songs add column if not exists moods text[] not null default '{}';

alter table arenas add column if not exists warmup_song_id uuid references songs(id) on delete set null;
alter table arenas add column if not exists warmup_started_at timestamptz;

-- Arenas are created only through create_arena (it also creates the warm-up
-- row); a direct insert would bypass the warm-up requirement.
drop policy if exists host_create_arena on arenas;

-- ============================================================
-- 2. Mood tags for the MVP curated library (approved by the user 2026-10-26)
-- ============================================================

update songs s
set moods = t.moods, updated_at = now()
from (values
  ('AstroPilot', 'Gravity Free', array['chill','ambient','electronic','lounge']),
  ('Beck', 'Heartland Feelings', array['indie','alternative','chill']),
  ('Blur', 'Country House', array['rock','indie','90s','feel-good']),
  ('Calexico', 'Black Heart', array['indie','alternative','folk','melancholic']),
  ('Chet Baker', 'Time After Time', array['jazz','romantic','lounge','chill']),
  ('DJ Shadow', 'Building Steam With a Grain of Salt', array['hip-hop','electronic','chill','90s']),
  ('Easy Star All-Stars', 'Billie Jean', array['reggae','feel-good','throwback','chill']),
  ('GMO vs. Dense', 'Passing Storm', array['trance','electronic','festival','energetic']),
  ('Grateful Dead', 'Friend of the Devil', array['rock','folk','acoustic','70s']),
  ('High Tone meets Brain Damage', 'The Dawn', array['reggae','electronic','chill']),
  ('Holy Other', 'Held', array['electronic','ambient','melancholic','late-night']),
  ('Iron Maiden', 'Run to the Hills', array['metal','rock','80s','energetic','workout']),
  ('Lone', 'The Animal Pattern', array['electronic','house','dance']),
  ('Michal Menert', 'In The Morning', array['electronic','lo-fi','chill','feel-good']),
  ('Nina Dioz', 'Chicos, Tenis y Cachucha', array['hip-hop','latin','party']),
  ('Of Monsters and Men', 'Little Talks', array['indie','folk','feel-good']),
  ('Orbital', 'New France (feat. Zola Jesus)', array['electronic','techno','epic']),
  ('PANTyRAID', 'Crunkalicious', array['electronic','hip-hop','party','energetic']),
  ('Paper Diamond', 'Levitate', array['electronic','dubstep','energetic']),
  ('Pretty Lights', 'I Know The Truth', array['electronic','hip-hop','funk','chill']),
  ('The Cinematic Orchestra', 'Lapis', array['jazz','ambient','chill','focus']),
  ('The Glitch Mob', 'Animus Vox', array['electronic','dubstep','epic','workout']),
  ('Thievery Corporation', 'Mandala', array['lounge','electronic','chill'])
) as t(artist, title, moods)
where s.arena_id = library_arena_id()
  and s.source = 'upload'
  and s.artist = t.artist
  and s.title = t.title;

-- ============================================================
-- 3. Warm-up never enters queues or battles
-- ============================================================

-- security definer: songs has no client SELECT policy, so as the invoker
-- (a participant inserting into queues) the lookup would see nothing
create or replace function reject_warmup_song()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_table_name = 'queues' then
    if exists (select 1 from songs where id = new.song_id and role = 'warmup') then
      raise exception 'the warm-up song cannot be queued' using errcode = '23514';
    end if;
  else
    if exists (
      select 1 from songs
      where id in (new.song_a_id, new.song_b_id, new.winner_song_id)
        and role = 'warmup'
    ) then
      raise exception 'the warm-up song cannot compete' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_queues_reject_warmup on queues;
create trigger trg_queues_reject_warmup
  before insert or update of song_id on queues
  for each row execute function reject_warmup_song();

drop trigger if exists trg_battles_reject_warmup on battles;
create trigger trg_battles_reject_warmup
  before insert or update of song_a_id, song_b_id, winner_song_id on battles
  for each row execute function reject_warmup_song();

-- Proposal search: never offer the arena's warm-up row
create or replace function public.search_songs(p_arena_id uuid, p_query text)
 returns table(id uuid, title text, artist text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select s.id, s.title, s.artist
  from songs s
  where exists (
          select 1 from participants p
          where p.arena_id = p_arena_id and p.identity_anchor_id = auth.uid())
    and s.arena_id in (p_arena_id, library_arena_id())
    and s.status = 'active'
    and s.source <> 'mock'
    and s.role = 'competitor'
    and (s.title ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or s.artist ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
  order by s.title
  limit 20;
$function$;

-- ============================================================
-- 4. Warm-up suggestions (Create Arena)
-- ============================================================

-- Library songs with audio; the arena mood's matches first, then the rest
create or replace function public.get_warmup_suggestions(p_mood text, p_query text default null)
 returns table(id uuid, title text, artist text, duration_ms integer, matches_mood boolean)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select s.id, s.title, s.artist, s.duration_ms, coalesce(p_mood = any(s.moods), false)
  from songs s
  where auth.uid() is not null
    and s.arena_id = library_arena_id()
    and s.status = 'active'
    and s.source <> 'mock'
    and s.audio_storage_path is not null
    and (coalesce(p_query, '') = ''
      or s.title ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or s.artist ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
  order by 5 desc, s.title;
$function$;

grant execute on function public.get_warmup_suggestions(text, text) to authenticated;

-- ============================================================
-- 5. create_arena: warm-up required
-- ============================================================

drop function if exists public.create_arena(text, text);

create or replace function public.create_arena(p_name text, p_mood text, p_warmup_song_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_arena_id uuid;
  v_src songs%rowtype;
  v_warmup_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_src
  from songs
  where id = p_warmup_song_id
    and arena_id = library_arena_id()
    and status = 'active'
    and source <> 'mock'
    and audio_storage_path is not null;

  if not found then
    raise exception 'a warm-up song from the library is required' using errcode = '22023';
  end if;

  -- mood validity/presence is enforced by arenas_mood_check +
  -- arenas_waiting_requires_mood
  insert into arenas (name, host_id, state, mood)
  values (p_name, auth.uid(), 'waiting', p_mood)
  returning id into v_arena_id;

  -- Block 3 §1: the arena gets its own Song with role = warmup
  insert into songs (
    arena_id, source, spotify_track_id, title, artist, duration_ms,
    energy, bpm, valence, popularity, status, audio_storage_path, role, moods
  )
  values (
    v_arena_id, v_src.source, v_src.spotify_track_id, v_src.title, v_src.artist, v_src.duration_ms,
    v_src.energy, v_src.bpm, v_src.valence, v_src.popularity, 'active', v_src.audio_storage_path, 'warmup', v_src.moods
  )
  returning id into v_warmup_id;

  update arenas set warmup_song_id = v_warmup_id where id = v_arena_id;

  perform ensure_mock_songs_for_arena(v_arena_id);

  return v_arena_id;
end;
$function$;

grant execute on function public.create_arena(text, text, uuid) to authenticated;

-- ============================================================
-- 6. start_arena_battles: starts the warm-up and creates battle 1
-- ============================================================

-- Replaces the create-battle Edge Function call (which inserted a battle with
-- the column defaults: global mock songs, 45 s). Returns the arena's open
-- battle id, creating battle 1 on the waiting -> active transition.
drop function if exists public.start_arena_battles(uuid);

create or replace function public.start_arena_battles(p_arena_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_arena arenas%rowtype;
  v_battle_id uuid;
  v_duration integer;
  v_warmup_track text;
  v_pair record;
  v_song_a uuid;
  v_song_b uuid;
begin
  select * into v_arena from arenas where id = p_arena_id for update;

  if not found then
    raise exception 'arena not found' using errcode = 'P0002';
  end if;
  if v_arena.host_id is distinct from auth.uid() then
    raise exception 'only the host can start battles' using errcode = '42501';
  end if;

  -- idempotent: host re-entering an arena that is already running
  if v_arena.state = 'active' then
    select id into v_battle_id
    from battles
    where arena_id = p_arena_id and state in ('pending', 'active', 'closing')
    order by created_at desc
    limit 1;

    if v_battle_id is not null then
      return v_battle_id;
    end if;
  elsif v_arena.state <> 'waiting' then
    raise exception 'arena is %', v_arena.state using errcode = '22023';
  end if;

  if v_arena.state = 'waiting' then
    update arenas
    set state = 'active',
        started_at = now(),
        warmup_started_at = case when warmup_song_id is not null then now() end,
        updated_at = now()
    where id = p_arena_id;

    -- Battle 1 lasts the warm-up (the "winner of battle 0")
    select duration_ms, spotify_track_id into v_duration, v_warmup_track
    from songs where id = v_arena.warmup_song_id;
  end if;

  -- Songs proposed during the lobby go first
  select * into v_pair from pull_next_battle_songs(p_arena_id);
  v_song_a := v_pair.song_a;
  v_song_b := v_pair.song_b;

  -- Nothing proposed yet: two library songs, arena mood first, never the
  -- warm-up track (instead of the old "Mock Song A/B" defaults)
  if v_song_a is null or v_song_b is null then
    select (array_agg(id))[1], (array_agg(id))[2]
    into v_song_a, v_song_b
    from (
      select id
      from songs
      where arena_id = library_arena_id()
        and status = 'active'
        and source <> 'mock'
        and role = 'competitor'
        and spotify_track_id is distinct from v_warmup_track
      order by coalesce(v_arena.mood = any(moods), false) desc, random()
      limit 2
    ) picked;
  end if;

  insert into battles (arena_id, song_a_id, song_b_id, state, duration_ms, sudden_death_active)
  values (
    p_arena_id,
    coalesce(v_song_a, '11111111-1111-1111-1111-111111111111'::uuid),
    coalesce(v_song_b, '22222222-2222-2222-2222-222222222222'::uuid),
    'pending',
    coalesce(v_duration, 45000),
    false
  )
  returning id into v_battle_id;

  return v_battle_id;
end;
$function$;

grant execute on function public.start_arena_battles(uuid) to authenticated;

-- ============================================================
-- 7. Reading the warm-up (Lobby, Battle Room, Stage View)
-- ============================================================

-- Any participant/host of the arena. audio_storage_path only for the host,
-- who is the provisional playback device.
create or replace function public.get_arena_warmup(p_arena_id uuid)
 returns table(
   song_id uuid, title text, artist text, duration_ms integer,
   started_at timestamptz, audio_storage_path text
 )
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select s.id, s.title, s.artist, s.duration_ms, a.warmup_started_at,
         case when a.host_id = auth.uid() then s.audio_storage_path end
  from arenas a
  join songs s on s.id = a.warmup_song_id
  where a.id = p_arena_id
    and (a.host_id = auth.uid()
      or exists (
        select 1 from participants p
        where p.arena_id = a.id and p.identity_anchor_id = auth.uid()));
$function$;

grant execute on function public.get_arena_warmup(uuid) to authenticated;

-- Host may sign a URL for their own arena's warm-up audio, only once battles
-- started (the lobby is silent). curated-songs stays private otherwise.
-- security definer for the same reason as reject_warmup_song (songs RLS)
create or replace function public.can_read_warmup_audio(p_object_name text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1
    from arenas a
    join songs s on s.id = a.warmup_song_id
    where a.host_id = auth.uid()
      and a.state = 'active'
      and s.audio_storage_path = p_object_name
  );
$function$;

drop policy if exists host_reads_active_warmup_audio on storage.objects;
create policy host_reads_active_warmup_audio
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'curated-songs'
    and public.can_read_warmup_audio(name)
  );
