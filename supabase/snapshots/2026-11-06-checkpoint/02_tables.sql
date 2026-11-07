create table public.account_merge_tickets (
  ticket text not null,
  anon_user_id uuid not null,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone default (now() + '00:10:00'::interval) not null
);
alter table public.account_merge_tickets enable row level security;

create table public.affinity_signals (
  id bigint generated always as identity not null,
  user_id uuid not null,
  isrc text not null,
  kind text not null,
  arena_id uuid,
  weight real not null,
  created_at timestamp with time zone default now() not null
);
alter table public.affinity_signals enable row level security;

create table public.arena_library_contributors (
  arena_id uuid not null,
  user_id uuid not null,
  created_at timestamp with time zone default now() not null
);
alter table public.arena_library_contributors enable row level security;

create table public.arena_pi_standings (
  arena_id uuid not null,
  user_id uuid,
  display_name text not null,
  pi integer not null,
  created_at timestamp with time zone default now() not null
);
alter table public.arena_pi_standings enable row level security;

create table public.arena_playback (
  arena_id uuid not null,
  host_id uuid not null,
  provider text default 'spotify'::text not null,
  playlist_id text,
  playlist_uri text,
  session_name text,
  device_id text,
  device_name text,
  is_playing boolean default false not null,
  current_track_uri text,
  progress_ms integer,
  resume_track_uri text,
  resume_position_ms integer,
  expected_until timestamp with time zone,
  strikes integer default 0 not null,
  strike_reason text,
  checked_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  control_mode text default 'auto'::text not null,
  manual_change_at timestamp with time zone,
  player_context text,
  put_back_uri text,
  put_back_count integer default 0 not null,
  wake_at timestamp with time zone,
  reserve_refill_after timestamp with time zone
);
alter table public.arena_playback enable row level security;

create table public.arena_song_reserve (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  song_id uuid not null,
  source text not null,
  created_at timestamp with time zone default now() not null,
  fit real,
  taste real,
  scored_at timestamp with time zone,
  contributed_by uuid
);
alter table public.arena_song_reserve enable row level security;

create table public.arenas (
  id uuid default gen_random_uuid() not null,
  host_id uuid,
  name text not null,
  state text default 'waiting'::text not null,
  mood text,
  started_at timestamp with time zone,
  ended_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  arena_code text default generate_arena_code() not null,
  votes_purged_at timestamp with time zone,
  warmup_song_id uuid,
  warmup_started_at timestamp with time zone,
  paused_at timestamp with time zone,
  pause_reason text,
  fallback_source text,
  warmup_unplayable_at timestamp with time zone
);
alter table public.arenas enable row level security;

create table public.battle_presence_snapshots (
  battle_id uuid not null,
  participant_id uuid not null,
  arena_id uuid not null,
  identity_anchor_id uuid not null,
  state text not null,
  last_active_at timestamp with time zone,
  captured_at timestamp with time zone default now() not null
);
alter table public.battle_presence_snapshots enable row level security;

create table public.battles (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  song_a_id uuid default '11111111-1111-1111-1111-111111111111'::uuid not null,
  song_b_id uuid default '22222222-2222-2222-2222-222222222222'::uuid not null,
  state text default 'pending'::text not null,
  winner_song_id uuid,
  started_at timestamp with time zone,
  ended_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  duration_ms integer default 45000 not null,
  lockin_at timestamp with time zone,
  sudden_death_active boolean default false not null,
  post_battle_processed_at timestamp with time zone,
  enqueue_done boolean default false not null,
  resolution_type text,
  sudden_death_started_at timestamp with time zone,
  final_votes_a integer,
  final_votes_b integer,
  final_passive_a real,
  final_passive_b real,
  soundtrack text default 'arena'::text not null,
  soundtrack_fitted_at timestamp with time zone,
  vote_token text default substr(md5((gen_random_uuid())::text), 1, 12)
);
alter table public.battles enable row level security;

create table public.cron_debug_log (
  id uuid default gen_random_uuid(),
  executed_at timestamp with time zone default now()
);
alter table public.cron_debug_log enable row level security;

create table public.cron_seconds_test_log (
  id bigint default nextval('cron_seconds_test_log_id_seq'::regclass) not null,
  fired_at timestamp with time zone default now()
);
alter table public.cron_seconds_test_log enable row level security;

create table public.hosts (
  id uuid default gen_random_uuid() not null,
  display_name text not null,
  email text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone not null
);
alter table public.hosts enable row level security;

create table public.matchmaking_config (
  id integer default 1 not null,
  continuity_weight real default 0.6 not null,
  pair_weight real default 0.4 not null,
  taste_weight real default 0.1 not null,
  turn_weight real default 0.15 not null,
  neutral_compat real default 0.35 not null,
  max_skips integer default 3 not null,
  log_retention_days integer default 30 not null,
  votes_weight real default 2.0 not null,
  list_vote_limit integer default 3 not null,
  duplicate_limit integer default 5 not null
);
alter table public.matchmaking_config enable row level security;

create table public.matchmaking_log (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  battle_id uuid,
  created_at timestamp with time zone default now() not null,
  ref_song_id uuid,
  song_a_id uuid,
  song_b_id uuid,
  a_source text,
  b_source text,
  forced boolean default false not null,
  score real,
  candidates jsonb,
  components jsonb
);
alter table public.matchmaking_log enable row level security;

create table public.mb_artists (
  mbid uuid not null,
  name text,
  tags text[] default '{}'::text[] not null,
  related_mbids uuid[] default '{}'::uuid[] not null,
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  next_attempt_at timestamp with time zone default now() not null,
  looked_up_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  lb_similar uuid[] default '{}'::uuid[] not null,
  aux_step text,
  aux_attempts integer default 0 not null,
  aux_next_at timestamp with time zone default now() not null
);
alter table public.mb_artists enable row level security;

create table public.mb_enrich_state (
  id integer default 1 not null,
  running_until timestamp with time zone,
  genres_loaded_at timestamp with time zone
);
alter table public.mb_enrich_state enable row level security;

create table public.mb_genres (
  name text not null
);
alter table public.mb_genres enable row level security;

create table public.participants (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  identity_anchor_id uuid not null,
  user_id uuid,
  display_name text default ''::text not null,
  avatar_url text,
  is_host boolean default false not null,
  joined_at timestamp with time zone default now() not null,
  last_active_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  left_at timestamp with time zone,
  last_seen_at timestamp with time zone,
  disconnected_at timestamp with time zone
);
alter table public.participants enable row level security;

create table public.passive_vote_config (
  id integer default 1 not null,
  min_score real default 0.7 not null,
  base_value real default 0.4 not null,
  boosted_value real default 0.5 not null,
  value_span real default 0.1 not null,
  boost_passive_ratio real default 0.75 not null,
  k_cap real default 1.25 not null,
  ramp_seconds integer default 30 not null,
  min_signals integer default 3 not null,
  half_life_days integer default 365 not null,
  top_tags integer default 10 not null,
  score_same_song real default 1.0 not null,
  score_same_artist real default 0.9 not null,
  score_related_artist real default 0.75 not null,
  score_tags_cap real default 0.85 not null,
  weight_like real default 1.0 not null,
  weight_proposal real default 1.0 not null,
  weight_vote real default 0.5 not null
);
alter table public.passive_vote_config enable row level security;

create table public.pi_config (
  id boolean default true not null,
  win integer not null,
  sudden_death_bonus integer not null,
  tie integer not null,
  battle_entry integer not null,
  backing_share numeric not null,
  entry_min_present integer default 2 not null
);
alter table public.pi_config enable row level security;

create table public.pi_ledger (
  id bigint generated always as identity not null,
  user_id uuid not null,
  arena_id uuid,
  battle_id uuid,
  song_id uuid,
  reason text not null,
  delta integer not null,
  created_at timestamp with time zone default now() not null
);
alter table public.pi_ledger enable row level security;

create table public.playback_events (
  id bigint generated always as identity not null,
  arena_id uuid not null,
  at timestamp with time zone default now() not null,
  kind text not null,
  detail jsonb default '{}'::jsonb not null
);
alter table public.playback_events enable row level security;

create table public.playlist_queue (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  battle_id uuid not null,
  winner_song_id uuid not null,
  spotify_track_id text not null,
  created_at timestamp with time zone default now() not null,
  song_duration_ms integer default 0 not null,
  seq bigint generated always as identity not null,
  added_to_playlist_at timestamp with time zone,
  unplayable_at timestamp with time zone,
  lead_in_ms integer default 0 not null,
  lead_in_track_uri text
);
alter table public.playlist_queue enable row level security;

create table public.privacy_consents (
  user_id uuid not null,
  policy_version text not null,
  accepted_at timestamp with time zone default now() not null
);
alter table public.privacy_consents enable row level security;

create table public.proposal_history (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  song_id uuid not null,
  proposed_by uuid not null,
  proposed_at timestamp with time zone not null,
  outcome text not null,
  battle_id uuid,
  ended_at timestamp with time zone default now() not null,
  kind text default 'proposal'::text not null,
  vote_applied boolean,
  vote_preassigned boolean,
  backing_source text
);
alter table public.proposal_history enable row level security;

create table public.queue_backers (
  arena_id uuid not null,
  song_id uuid not null,
  user_id uuid not null,
  created_at timestamp with time zone default now() not null,
  source text default 'duplicate'::text not null
);
alter table public.queue_backers enable row level security;

create table public.queues (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  song_id uuid not null,
  queue_type text default 'waiting'::text not null,
  "position" integer not null,
  priority integer not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  proposed_by uuid,
  battles_waited integer default 0 not null,
  times_skipped integer default 0 not null
);
alter table public.queues enable row level security;

create table public.recordings (
  isrc text not null,
  mbid uuid,
  artist_mbids uuid[] default '{}'::uuid[] not null,
  tags text[] default '{}'::text[] not null,
  status text default 'pending'::text not null,
  attempts integer default 0 not null,
  next_attempt_at timestamp with time zone default now() not null,
  looked_up_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  match_source text default 'isrc'::text not null,
  lb_tags text[] default '{}'::text[] not null,
  aux_step text,
  aux_attempts integer default 0 not null,
  aux_next_at timestamp with time zone default now() not null
);
alter table public.recordings enable row level security;

create table public.song_likes (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  song_id uuid not null,
  participant_id uuid not null,
  created_at timestamp with time zone default now() not null,
  added_to_spotify_at timestamp with time zone
);
alter table public.song_likes enable row level security;

create table public.songs (
  id uuid default gen_random_uuid() not null,
  arena_id uuid not null,
  source text not null,
  spotify_track_id text not null,
  title text not null,
  artist text not null,
  duration_ms integer not null,
  energy real,
  bpm real,
  valence real,
  popularity integer,
  status text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  audio_storage_path text,
  role text default 'competitor'::text not null,
  moods text[] default '{}'::text[] not null,
  artwork_url text,
  isrc text
);
alter table public.songs enable row level security;

create table public.spotify_oauth_states (
  state text not null,
  user_id uuid not null,
  code_verifier text not null,
  redirect_uri text not null,
  return_to text not null,
  expires_at timestamp with time zone default (now() + '00:10:00'::interval) not null,
  created_at timestamp with time zone default now() not null
);
alter table public.spotify_oauth_states enable row level security;

create table public.spotify_rate_limit (
  id boolean default true not null,
  until timestamp with time zone not null,
  updated_at timestamp with time zone default now() not null
);
alter table public.spotify_rate_limit enable row level security;

create table public.streaming_accounts (
  id uuid default gen_random_uuid() not null,
  host_id uuid not null,
  provider text default 'spotify'::text not null,
  provider_account_id text not null,
  display_name text,
  access_token_enc text not null,
  refresh_token_enc text not null,
  token_expires_at timestamp with time zone not null,
  scopes text[] default '{}'::text[] not null,
  premium_status text default 'unverified'::text not null,
  premium_checked_at timestamp with time zone,
  preferred_device_id text,
  preferred_device_name text,
  connected_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  country text
);
alter table public.streaming_accounts enable row level security;

create table public.system_song_config (
  id integer default 1 not null,
  style_half_life_minutes integer default 60 not null,
  fit_bucket real default 0.1 not null,
  host_library_pool integer default 8 not null,
  guest_library_pool integer default 4 not null,
  arena_artist_pool integer default 3 not null,
  rotate_every_minutes integer default 5 not null,
  rotate_min_age_minutes integer default 10 not null
);
alter table public.system_song_config enable row level security;

create table public.user_profiles (
  user_id uuid not null,
  nickname text,
  country text,
  updated_at timestamp with time zone default now() not null
);
alter table public.user_profiles enable row level security;

create table public.votes (
  id uuid default gen_random_uuid() not null,
  arena_id uuid,
  battle_id uuid not null,
  song_id uuid not null,
  participant_id uuid not null,
  identity_anchor_id uuid not null,
  vote_type text default 'regular'::text not null,
  weight real default 1 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  status text default 'active'::text not null,
  preassigned boolean default false not null
);
alter table public.votes enable row level security;
