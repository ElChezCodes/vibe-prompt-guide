-- ===========================================================================
-- Roadmap step 15 (2026-10-28): Prestige Influence (PI) + leaderboards.
--
-- Spec: v4 §7.1 + pi_logs schema, v3.2 assignPIOnWin / pi_logs, v3.0 §7,
-- v2.6 §11.2, Backend_Block_2 §9 (the warm-up gives no PI; "propuesta
-- aceptada -> PI"). The spec says "full PI / 50 % / bonus" without numbers.
--
-- User decisions 2026-10-28 (numbers live in pi_config, an UPDATE changes them):
--   * Win (original proposer) = 10 PI; won in Sudden Death = +5 bonus.
--   * Draw (both songs sound) = 5 PI to each proposer + the Sudden Death
--     bonus (a draw always went through Sudden Death) = 10 each.
--   * Reaching a battle = +1 PI to the proposer, win or lose (awarded when
--     the battle row is created; kept if the battle is later cancelled).
--   * Backings (step 14) = 50 % of what the original proposer gets for the
--     win (rounded), only if the vote was pre-assigned at the start of the
--     battle AND the backer's counted vote when the battle completes is for
--     that song (regular, or Sudden Death once SD started). Switched to the
--     other song, abstained, not cast (left the arena, both songs backed and
--     the other one used) or a backing made while the song was already
--     fighting ('voted'): nothing.
--   * Cancelled battles, losers, system songs (reserve, revancha, artist
--     search: no proposal_history row of kind 'proposal') and the warm-up
--     (never in battles): nothing.
--   * The −5 PI first-infraction penalty is postponed until moderation
--     exists; the ledger already accepts reason 'penalty' (negative delta).
--     Totals are shown floored at 0.
--   * Awarded from SQL only (battles triggers), never from the client;
--     nothing here touches timing or playback (step 18).
--
-- Ledger (engineering addition #2): pi_ledger, one row per award with a
-- unique (user, battle, song, reason) key and ON CONFLICT DO NOTHING, so a
-- retried or replayed event never awards twice. Service-only.
--
-- Leaderboards (user decisions 2026-10-28):
--   * Local = per arena: the current arena and the past ones the user was in
--     (get_arena_pi_leaderboard, get_my_past_arenas). Everyone in the arena,
--     anonymous included.
--   * Global = world and per country, this month (UTC) and all-time
--     (get_pi_leaderboard). Accounts only (step 7b): anonymous users earn PI
--     and appear in their arenas; merging into an account moves their PI.
--   * Name = a generated nickname ("Neon Falcon 42", derived from the user
--     id, nothing stored) the user may change in Profile (user_profiles).
--     Never the Spotify name or the email.
--   * Country = declared by the user in Profile (optional, ISO 3166-1
--     alpha-2); their own Spotify country is only suggested. No country =
--     world leaderboard only.
--   * Retention like affinity_signals: accounts keep their PI until
--     delete_account (FK cascade); anonymous users' rows are deleted by the
--     30-day purge (unless merged before). Each arena's final ranking is
--     kept (arena_pi_standings, snapshot at the purge).
--   * Display: Ranking tab + "Your PI" chip and award notice in the Battle
--     Room (get_my_pi). PI in the Stage View is left for later (step 19).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Rules (one row)
-- ---------------------------------------------------------------------------
create table if not exists public.pi_config (
  id boolean primary key default true check (id),
  win integer not null,
  sudden_death_bonus integer not null,
  tie integer not null,
  battle_entry integer not null,
  backing_share numeric not null
);
insert into public.pi_config (id, win, sudden_death_bonus, tie, battle_entry, backing_share)
values (true, 10, 5, 5, 1, 0.5)
on conflict (id) do nothing;
alter table public.pi_config enable row level security;
revoke all on public.pi_config from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Ledger (service-only)
-- ---------------------------------------------------------------------------
create table if not exists public.pi_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  arena_id uuid references public.arenas(id) on delete cascade,
  battle_id uuid references public.battles(id) on delete cascade,
  song_id uuid references public.songs(id) on delete set null,
  reason text not null check (reason in
    ('battle_entry', 'win', 'tie', 'sudden_death_bonus', 'duplicate_half', 'penalty')),
  delta integer not null,
  created_at timestamptz not null default now(),
  constraint pi_ledger_event_unique unique nulls not distinct (user_id, battle_id, song_id, reason)
);
create index if not exists pi_ledger_arena_idx on public.pi_ledger (arena_id, user_id);
create index if not exists pi_ledger_created_idx on public.pi_ledger (created_at);
alter table public.pi_ledger enable row level security;
revoke all on public.pi_ledger from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Profile: nickname + declared country (service-only, through RPCs)
-- ---------------------------------------------------------------------------
create table if not exists public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nickname text check (nickname is null or char_length(nickname) between 2 and 20),
  country text check (country is null or country ~ '^[A-Z]{2}$'),
  updated_at timestamptz not null default now()
);
create index if not exists user_profiles_country_idx on public.user_profiles (country);
alter table public.user_profiles enable row level security;
revoke all on public.user_profiles from anon, authenticated;

-- Each arena's final ranking, kept after the 30-day purge (service-only)
create table if not exists public.arena_pi_standings (
  arena_id uuid not null references public.arenas(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  display_name text not null,
  pi integer not null,
  created_at timestamptz not null default now()
);
create index if not exists arena_pi_standings_arena_idx on public.arena_pi_standings (arena_id);
create index if not exists arena_pi_standings_user_idx on public.arena_pi_standings (user_id);
alter table public.arena_pi_standings enable row level security;
revoke all on public.arena_pi_standings from anon, authenticated;

-- A backing whose vote was written when its battle started (step 14's
-- vote_applied may also turn true later, through 'voted', which gives no PI)
alter table public.proposal_history add column if not exists vote_preassigned boolean;

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------
create or replace function public.mf_generated_nickname(p_user uuid)
returns text
language sql
immutable
set search_path = public
as $$
  with h as (select md5(p_user::text) as m),
  w as (
    select array['Neon','Electric','Cosmic','Golden','Turbo','Velvet','Midnight','Sonic','Crimson','Lunar',
                 'Atomic','Funky','Mystic','Solar','Wild','Silver','Hyper','Groovy','Retro','Thunder',
                 'Shadow','Crystal','Blazing','Stellar','Rocket','Jazzy','Laser','Mighty','Lucky','Royal',
                 'Pixel','Rebel'] as adj,
           array['Falcon','Tiger','Panda','Comet','Wolf','Fox','Phoenix','Dragon','Shark','Lynx',
                 'Raven','Cobra','Otter','Koala','Jaguar','Mantis','Orca','Bison','Gecko','Hawk',
                 'Lion','Owl','Puma','Rhino','Yak','Zebra','Badger','Beetle','Dolphin','Moose',
                 'Parrot','Viper'] as noun
  )
  select w.adj[1 + ('x' || substr(h.m, 1, 6))::bit(24)::int % 32] || ' ' ||
         w.noun[1 + ('x' || substr(h.m, 7, 6))::bit(24)::int % 32] || ' ' ||
         (('x' || substr(h.m, 13, 6))::bit(24)::int % 100)::text
  from h, w;
$$;

create or replace function public.mf_display_name(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select nickname from user_profiles where user_id = p_user), mf_generated_nickname(p_user));
$$;
revoke all on function public.mf_display_name(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Awards (service-only; idempotent by the ledger key)
-- ---------------------------------------------------------------------------
create or replace function public.award_pi(p_user uuid, p_arena uuid, p_battle uuid, p_song uuid,
                                           p_reason text, p_delta integer)
returns void
language sql
security definer
set search_path = public
as $$
  insert into pi_ledger (user_id, arena_id, battle_id, song_id, reason, delta)
  select p_user, p_arena, p_battle, p_song, p_reason, p_delta
  where p_user is not null and p_delta <> 0
    and exists (select 1 from auth.users where id = p_user)
  on conflict on constraint pi_ledger_event_unique do nothing;
$$;
revoke all on function public.award_pi(uuid, uuid, uuid, uuid, text, integer) from public, anon, authenticated;

-- +1 to each original proposer whose song reaches a battle. Runs after
-- trg_battles_link_proposals (triggers fire in name order), which links the
-- queue rows pulled into this battle.
create or replace function public.pi_on_battle_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry integer;
  r record;
begin
  select battle_entry into v_entry from pi_config where id;
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled' and h.proposed_by is not null
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'battle_entry', v_entry);
  end loop;
  return null;
end;
$$;

drop trigger if exists trg_battles_pi_entry on public.battles;
create trigger trg_battles_pi_entry
  after insert on public.battles
  for each row execute function public.pi_on_battle_created();

-- Win / draw / Sudden Death bonus / half to backers, when the battle completes
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

  -- Original proposers (system songs have none)
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled'
      and h.proposed_by is not null and h.song_id = any (v_songs)
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, v_reason, v_base);
    if v_sd then
      perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'sudden_death_bonus', c.sudden_death_bonus);
    end if;
  end loop;

  -- Backers: pre-assigned at the start and still their counted vote at the end
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'backing' and h.vote_preassigned
      and h.proposed_by is not null and h.song_id = any (v_songs)
      and exists (select 1 from votes v
                  where v.battle_id = new.id and v.identity_anchor_id = h.proposed_by
                    and v.song_id = h.song_id and v.status = 'active' and v.vote_type <> 'passive'
                    and (new.sudden_death_started_at is null or v.vote_type = 'sudden_death'))
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'duplicate_half',
                     round((v_base + case when v_sd then c.sudden_death_bonus else 0 end) * c.backing_share)::integer);
  end loop;

  return null;
end;
$$;

drop trigger if exists trg_battles_pi_awards on public.battles;
create trigger trg_battles_pi_awards
  after update of state on public.battles
  for each row
  when (new.state = 'completed' and old.state is distinct from 'completed')
  execute function public.pi_on_battle_completed();

-- ---------------------------------------------------------------------------
-- Step 14's trigger, now also stamping vote_preassigned on the backing rows
-- ---------------------------------------------------------------------------
create or replace function public.apply_preassigned_votes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from queue_backers k
                 where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)) then
    return null;
  end if;

  perform set_config('mf.preassigning', 'on', true);
  -- Backers still in the arena; both songs backed -> the oldest backing
  insert into votes (battle_id, song_id, participant_id, identity_anchor_id, vote_type, status, preassigned)
  select distinct on (k.user_id) new.id, k.song_id, p.id, k.user_id, 'regular', 'active', true
  from queue_backers k
  join participants p on p.arena_id = k.arena_id and p.identity_anchor_id = k.user_id and p.left_at is null
  where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)
  order by k.user_id, k.created_at, k.song_id
  on conflict (battle_id, participant_id) do nothing;
  perform set_config('mf.preassigning', '', true);

  with gone as (
    delete from queue_backers k
    where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)
    returning k.*
  ),
  applied as (
    select g.*,
           exists (select 1 from votes v
                   where v.battle_id = new.id and v.identity_anchor_id = g.user_id
                     and v.song_id = g.song_id and v.preassigned) as cast_now
    from gone g
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, battle_id, kind,
                                vote_applied, vote_preassigned)
  select a.arena_id, a.song_id, a.user_id, a.created_at, 'battled', new.id, 'backing', a.cast_now, a.cast_now
  from applied a;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Purge (Block 5 §6): snapshot each arena's final ranking, then anonymous
-- users' PI goes with their votes; accounts keep theirs.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_arena_votes(p_retention interval DEFAULT '30 days'::interval)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select id from arenas
    where state in ('finished', 'expired')
      and votes_purged_at is null
      and coalesce(ended_at, updated_at) < now() - p_retention
  loop
    update battles b
    set final_votes_a = c.va, final_votes_b = c.vb,
        final_passive_a = c.pa, final_passive_b = c.pb
    from (
      select b2.id,
        count(v.id) filter (where v.song_id = b2.song_a_id and v.status = 'active' and v.vote_type <> 'passive'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as va,
        count(v.id) filter (where v.song_id = b2.song_b_id and v.status = 'active' and v.vote_type <> 'passive'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as vb,
        coalesce(sum(v.weight) filter (where v.song_id = b2.song_a_id and v.status = 'active' and v.vote_type = 'passive'), 0)::real as pa,
        coalesce(sum(v.weight) filter (where v.song_id = b2.song_b_id and v.status = 'active' and v.vote_type = 'passive'), 0)::real as pb
      from battles b2
      left join votes v on v.battle_id = b2.id
      where b2.arena_id = r.id
      group by b2.id
    ) c
    where b.id = c.id;

    delete from votes v using battles b
    where v.battle_id = b.id and b.arena_id = r.id;

    delete from battle_presence_snapshots where arena_id = r.id;
    delete from proposal_history where arena_id = r.id;
    delete from queue_backers where arena_id = r.id;  -- Step 14

    -- Anonymous users' in-arena profile goes with the votes; accounts keep theirs
    delete from affinity_signals s
    using auth.users u
    where s.arena_id = r.id and u.id = s.user_id and u.is_anonymous;

    -- Step 15: the arena's final ranking stays; anonymous PI rows go
    delete from arena_pi_standings where arena_id = r.id;
    insert into arena_pi_standings (arena_id, user_id, display_name, pi)
    select r.id, x.uid, mf_display_name(x.uid), x.pi
    from (
      select p.identity_anchor_id as uid,
             greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                                   where l.arena_id = r.id and l.user_id = p.identity_anchor_id), 0))::int as pi
      from participants p
      where p.arena_id = r.id
        and exists (select 1 from auth.users u where u.id = p.identity_anchor_id)
      group by p.identity_anchor_id
    ) x;
    delete from pi_ledger l
    using auth.users u
    where l.arena_id = r.id and u.id = l.user_id and u.is_anonymous;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Merge (step 7b): the anonymous user's PI, nickname/country and arena
-- standings move to the account
-- ---------------------------------------------------------------------------
create or replace function public.merge_anonymous_user(p_from uuid, p_to uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_to_participant uuid;
  v_moved int := 0;
  v_fused int := 0;
begin
  if p_from = p_to then
    raise exception 'same user';
  end if;
  if not exists (select 1 from auth.users where id = p_from and is_anonymous) then
    raise exception 'source is not an anonymous user';
  end if;
  if not exists (select 1 from auth.users where id = p_to and not is_anonymous) then
    raise exception 'target is not an account';
  end if;

  -- Hosting
  update arenas set host_id = p_to where host_id = p_from;
  update arena_playback set host_id = p_to where host_id = p_from;

  for r in select * from participants where identity_anchor_id = p_from loop
    select id into v_to_participant
    from participants where arena_id = r.arena_id and identity_anchor_id = p_to;

    if v_to_participant is null then
      update participants
      set identity_anchor_id = p_to,
          is_host = exists (select 1 from arenas a where a.id = r.arena_id and a.host_id = p_to)
      where id = r.id;
      v_moved := v_moved + 1;
    else
      -- Votes: one row per participant and battle; keep the most recent
      delete from votes v
      using votes w
      where v.battle_id = w.battle_id
        and ((v.participant_id = r.id and w.participant_id = v_to_participant and w.updated_at >= v.updated_at)
          or (v.participant_id = v_to_participant and w.participant_id = r.id and w.updated_at > v.updated_at));
      update votes set participant_id = v_to_participant where participant_id = r.id;

      delete from song_likes l
      where l.participant_id = r.id
        and exists (select 1 from song_likes k
                    where k.participant_id = v_to_participant and k.arena_id = l.arena_id and k.song_id = l.song_id);
      update song_likes set participant_id = v_to_participant where participant_id = r.id;

      delete from battle_presence_snapshots s
      where s.participant_id = r.id
        and exists (select 1 from battle_presence_snapshots k
                    where k.participant_id = v_to_participant and k.battle_id = s.battle_id);
      update battle_presence_snapshots set participant_id = v_to_participant where participant_id = r.id;

      update participants p
      set joined_at = least(p.joined_at, r.joined_at),
          last_active_at = greatest(p.last_active_at, r.last_active_at),
          last_seen_at = greatest(p.last_seen_at, r.last_seen_at),
          -- Still in the arena if either side was
          left_at = case when p.left_at is null or r.left_at is null then null
                         else greatest(p.left_at, r.left_at) end,
          disconnected_at = case when p.disconnected_at is null or r.disconnected_at is null then null
                                 else greatest(p.disconnected_at, r.disconnected_at) end,
          is_host = exists (select 1 from arenas a where a.id = r.arena_id and a.host_id = p_to)
      where p.id = v_to_participant;

      delete from participants where id = r.id;
      v_fused := v_fused + 1;
    end if;
  end loop;

  update votes set identity_anchor_id = p_to where identity_anchor_id = p_from;
  update battle_presence_snapshots set identity_anchor_id = p_to where identity_anchor_id = p_from;
  update queues set proposed_by = p_to where proposed_by = p_from;
  update proposal_history set proposed_by = p_to where proposed_by = p_from;

  -- Step 14: backings (one per song; none for a song the account proposed)
  delete from queue_backers a
  using queue_backers b
  where a.user_id = p_from and b.user_id = p_to and a.arena_id = b.arena_id and a.song_id = b.song_id;
  update queue_backers set user_id = p_to where user_id = p_from;
  delete from queue_backers k
  using queues q
  where k.user_id = p_to and q.arena_id = k.arena_id and q.song_id = k.song_id and q.proposed_by = p_to;

  -- Step 8: the anonymous in-arena profile becomes part of the account's
  delete from affinity_signals a
  using affinity_signals b
  where a.user_id = p_from and b.user_id = p_to
    and a.kind = b.kind and a.isrc = b.isrc and a.arena_id is not distinct from b.arena_id;
  update affinity_signals set user_id = p_to where user_id = p_from;

  -- Step 15: PI (same event on both sides = counted once), nickname/country
  -- only if the account has none, purged arenas' standings combined
  delete from pi_ledger a
  using pi_ledger b
  where a.user_id = p_from and b.user_id = p_to
    and a.battle_id is not distinct from b.battle_id
    and a.song_id is not distinct from b.song_id
    and a.reason = b.reason;
  update pi_ledger set user_id = p_to where user_id = p_from;

  if exists (select 1 from user_profiles where user_id = p_to) then
    update user_profiles t
    set nickname = coalesce(t.nickname, f.nickname),
        country = coalesce(t.country, f.country),
        updated_at = now()
    from user_profiles f
    where t.user_id = p_to and f.user_id = p_from;
    delete from user_profiles where user_id = p_from;
  else
    update user_profiles set user_id = p_to where user_id = p_from;
  end if;

  update arena_pi_standings t
  set pi = t.pi + f.pi
  from arena_pi_standings f
  where t.user_id = p_to and f.user_id = p_from and f.arena_id = t.arena_id;
  delete from arena_pi_standings f
  where f.user_id = p_from
    and exists (select 1 from arena_pi_standings t where t.user_id = p_to and t.arena_id = f.arena_id);
  update arena_pi_standings set user_id = p_to where user_id = p_from;

  delete from spotify_oauth_states where user_id = p_from;
  delete from account_merge_tickets where anon_user_id = p_from;

  return jsonb_build_object('arenas_moved', v_moved, 'arenas_fused', v_fused);
end;
$$;

-- ---------------------------------------------------------------------------
-- Client RPCs
-- ---------------------------------------------------------------------------

-- Own profile: name shown in leaderboards, declared country (+ their own
-- Spotify country as a suggestion only), PI totals
create or replace function public.get_my_profile()
returns table (nickname text, is_generated boolean, country text, suggested_country text,
               is_account boolean, total_pi integer, month_pi integer)
language sql
stable
security definer
set search_path = public
as $$
  select mf_display_name(u.id),
         (select p.nickname from user_profiles p where p.user_id = u.id) is null,
         (select p.country from user_profiles p where p.user_id = u.id),
         (select s.country from streaming_accounts s where s.host_id = u.id limit 1),
         not u.is_anonymous,
         greatest(0, coalesce((select sum(l.delta) from pi_ledger l where l.user_id = u.id), 0))::int,
         greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                               where l.user_id = u.id
                                 and l.created_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc'), 0))::int
  from auth.users u
  where u.id = auth.uid();
$$;
revoke all on function public.get_my_profile() from public, anon;
grant execute on function public.get_my_profile() to authenticated;

-- Empty/NULL nickname = back to the generated one; empty/NULL country = none
create or replace function public.update_my_profile(p_nickname text, p_country text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_nick text := nullif(regexp_replace(btrim(coalesce(p_nickname, '')), '\s+', ' ', 'g'), '');
  v_country text := nullif(upper(btrim(coalesce(p_country, ''))), '');
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if v_nick is not null and (char_length(v_nick) not between 2 and 20 or v_nick ~ '[[:cntrl:]]') then
    raise exception 'invalid_nickname' using errcode = 'P0001';
  end if;
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then
    raise exception 'invalid_country' using errcode = 'P0001';
  end if;

  insert into user_profiles (user_id, nickname, country)
  values (v_uid, v_nick, v_country)
  on conflict (user_id) do update
    set nickname = excluded.nickname, country = excluded.country, updated_at = now();
end;
$$;
revoke all on function public.update_my_profile(text, text) from public, anon;
grant execute on function public.update_my_profile(text, text) to authenticated;

-- "Your PI" in the Battle Room: PI in this arena, overall, and the latest
-- awards here (the client shows a notice for ones it hasn't seen)
create or replace function public.get_my_pi(p_arena_id uuid)
returns table (arena_pi integer, total_pi integer, recent jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                               where l.user_id = auth.uid() and l.arena_id = p_arena_id), 0))::int,
         greatest(0, coalesce((select sum(l.delta) from pi_ledger l where l.user_id = auth.uid()), 0))::int,
         coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'reason', x.reason, 'delta', x.delta,
                                                       'battle_id', x.battle_id, 'created_at', x.created_at)
                                    order by x.id desc)
                   from (select l.id, l.reason, l.delta, l.battle_id, l.created_at
                         from pi_ledger l
                         where l.user_id = auth.uid() and l.arena_id = p_arena_id
                         order by l.id desc limit 10) x), '[]'::jsonb)
  where auth.uid() is not null;
$$;
revoke all on function public.get_my_pi(uuid) from public, anon;
grant execute on function public.get_my_pi(uuid) to authenticated;

-- Local leaderboard: everyone who was in the arena (members and the host
-- only). Purged arenas read their kept final ranking.
create or replace function public.get_arena_pi_leaderboard(p_arena_id uuid)
returns table (place bigint, display_name text, pi integer, is_me boolean, is_host boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_arena arenas;
begin
  select * into v_arena from arenas where id = p_arena_id;
  if v_uid is null or v_arena.id is null
     or not (v_arena.host_id = v_uid
             or exists (select 1 from participants p where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid)) then
    return;
  end if;

  if v_arena.votes_purged_at is not null then
    return query
      select rank() over (order by s.pi desc),
             coalesce((select up.nickname from user_profiles up where up.user_id = s.user_id), s.display_name),
             s.pi, s.user_id is not distinct from v_uid, s.user_id is not distinct from v_arena.host_id
      from arena_pi_standings s
      where s.arena_id = p_arena_id
      order by s.pi desc, s.display_name;
    return;
  end if;

  return query
    with members as (
      select distinct p.identity_anchor_id as uid
      from participants p
      where p.arena_id = p_arena_id
        and exists (select 1 from auth.users u where u.id = p.identity_anchor_id)
    ),
    scored as (
      select m.uid,
             greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                                   where l.arena_id = p_arena_id and l.user_id = m.uid), 0))::int as pi
      from members m
    )
    select rank() over (order by s.pi desc), mf_display_name(s.uid), s.pi,
           s.uid = v_uid, s.uid = v_arena.host_id
    from scored s
    order by s.pi desc, 2;
end;
$$;
revoke all on function public.get_arena_pi_leaderboard(uuid) from public, anon;
grant execute on function public.get_arena_pi_leaderboard(uuid) to authenticated;

-- Past arenas the caller was in (finished/expired), newest first
create or replace function public.get_my_past_arenas(p_limit integer default 20)
returns table (arena_id uuid, arena_code text, name text, ended_at timestamptz, players bigint,
               my_pi integer, my_place bigint)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, a.arena_code, a.name, coalesce(a.ended_at, a.updated_at),
         (select count(*) from get_arena_pi_leaderboard(a.id)),
         (select lb.pi from get_arena_pi_leaderboard(a.id) lb where lb.is_me limit 1),
         (select lb.place from get_arena_pi_leaderboard(a.id) lb where lb.is_me limit 1)
  from arenas a
  where a.state in ('finished', 'expired')
    and auth.uid() is not null
    and exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid())
  order by coalesce(a.ended_at, a.updated_at) desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;
revoke all on function public.get_my_past_arenas(integer) from public, anon;
grant execute on function public.get_my_past_arenas(integer) to authenticated;

-- Global leaderboard: accounts only. p_scope 'world' | 'country' (p_country,
-- else the caller's declared one), p_period 'month' (UTC) | 'all'. Top
-- p_limit with PI > 0, plus the caller's own row (is_me) when outside it.
create or replace function public.get_pi_leaderboard(p_scope text, p_period text,
                                                     p_country text default null, p_limit integer default 50)
returns table (place bigint, display_name text, country text, pi integer, is_me boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_country text := upper(nullif(btrim(coalesce(p_country, '')), ''));
  v_since timestamptz := case when p_period = 'month'
                              then date_trunc('month', now() at time zone 'utc') at time zone 'utc' end;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if v_uid is null or p_scope not in ('world', 'country') or p_period not in ('month', 'all') then
    return;
  end if;
  if p_scope = 'country' then
    v_country := coalesce(v_country, (select up.country from user_profiles up where up.user_id = v_uid));
    if v_country is null then
      return;
    end if;
  end if;

  return query
    with totals as (
      select l.user_id, greatest(0, sum(l.delta))::int as pi
      from pi_ledger l
      join auth.users u on u.id = l.user_id and not u.is_anonymous
      left join user_profiles up on up.user_id = l.user_id
      where (v_since is null or l.created_at >= v_since)
        and (p_scope = 'world' or up.country = v_country)
      group by l.user_id
    ),
    ranked as (
      select t.user_id, t.pi, rank() over (order by t.pi desc) as place,
             row_number() over (order by t.pi desc, t.user_id) as rn
      from totals t
      where t.pi > 0
    )
    select r.place, mf_display_name(r.user_id),
           (select up.country from user_profiles up where up.user_id = r.user_id),
           r.pi, r.user_id = v_uid
    from ranked r
    where r.rn <= v_limit or r.user_id = v_uid
    order by r.rn;
end;
$$;
revoke all on function public.get_pi_leaderboard(text, text, text, integer) from public, anon;
grant execute on function public.get_pi_leaderboard(text, text, text, integer) to authenticated;
