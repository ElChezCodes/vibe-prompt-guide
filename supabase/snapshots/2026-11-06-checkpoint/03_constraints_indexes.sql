alter table account_merge_tickets add constraint account_merge_tickets_pkey PRIMARY KEY (ticket);

alter table affinity_signals add constraint affinity_signals_kind_check CHECK ((kind = ANY (ARRAY['vote'::text, 'proposal'::text, 'like'::text])));

alter table affinity_signals add constraint affinity_signals_pkey PRIMARY KEY (id);

alter table affinity_signals add constraint affinity_signals_unique UNIQUE NULLS NOT DISTINCT (user_id, kind, isrc, arena_id);

alter table arena_library_contributors add constraint arena_library_contributors_pkey PRIMARY KEY (arena_id, user_id);

alter table arena_playback add constraint arena_playback_control_mode_check CHECK ((control_mode = ANY (ARRAY['auto'::text, 'manual'::text])));

alter table arena_playback add constraint arena_playback_pkey PRIMARY KEY (arena_id);

alter table arena_playback add constraint arena_playback_provider_check CHECK ((provider = 'spotify'::text));

alter table arena_song_reserve add constraint arena_song_reserve_arena_id_song_id_key UNIQUE (arena_id, song_id);

alter table arena_song_reserve add constraint arena_song_reserve_pkey PRIMARY KEY (id);

alter table arena_song_reserve add constraint arena_song_reserve_source_check CHECK ((source = ANY (ARRAY['host_library'::text, 'guest_library'::text, 'arena_artist'::text])));

alter table arenas add constraint arenas_mood_check CHECK (((mood IS NULL) OR (mood = ANY (ARRAY['chill'::text, 'party'::text, 'energetic'::text, 'romantic'::text, 'dance'::text, 'workout'::text, 'focus'::text, 'sunset'::text, 'brunch'::text, 'late-night'::text, 'after-party'::text, 'lounge'::text, 'karaoke'::text, 'festival'::text, 'tropical'::text, 'feel-good'::text, 'melancholic'::text, 'epic'::text, 'pop'::text, 'rock'::text, 'indie'::text, 'alternative'::text, 'metal'::text, 'punk'::text, 'hip-hop'::text, 'r-and-b'::text, 'soul'::text, 'funk'::text, 'jazz'::text, 'blues'::text, 'country'::text, 'folk'::text, 'acoustic'::text, 'classical'::text, 'gospel'::text, 'reggae'::text, 'afrobeats'::text, 'k-pop'::text, 'lo-fi'::text, 'ambient'::text, 'electronic'::text, 'house'::text, 'techno'::text, 'trance'::text, 'drum-and-bass'::text, 'dubstep'::text, 'synthwave'::text, 'disco'::text, 'latin'::text, 'reggaeton'::text, 'salsa'::text, 'bachata'::text, 'cumbia'::text, 'merengue'::text, 'flamenco'::text, 'rumba'::text, 'tango'::text, '70s'::text, '80s'::text, '90s'::text, '2000s'::text, 'throwback'::text, 'custom'::text]))));

alter table arenas add constraint arenas_pause_reason_check CHECK ((((paused_at IS NULL) AND (pause_reason IS NULL)) OR ((paused_at IS NOT NULL) AND (pause_reason = ANY (ARRAY['device_lost'::text, 'playback_paused'::text, 'off_playlist'::text, 'spotify_disconnected'::text])))));

alter table arenas add constraint arenas_pkey PRIMARY KEY (id);

alter table arenas add constraint arenas_state_check CHECK ((state = ANY (ARRAY['waiting'::text, 'active'::text, 'finished'::text, 'expired'::text])));

alter table arenas add constraint arenas_waiting_requires_mood CHECK (((state <> 'waiting'::text) OR (mood IS NOT NULL)));

alter table battle_presence_snapshots add constraint battle_presence_snapshots_pkey PRIMARY KEY (battle_id, participant_id);

alter table battle_presence_snapshots add constraint battle_presence_snapshots_state_check CHECK ((state = ANY (ARRAY['active'::text, 'passive'::text, 'inactive'::text])));

alter table battles add constraint battles_active_no_resolution CHECK (((state <> 'active'::text) OR ((winner_song_id IS NULL) AND (resolution_type IS NULL))));

alter table battles add constraint battles_closing_requires_lockin CHECK (((state <> 'closing'::text) OR (lockin_at IS NOT NULL)));

alter table battles add constraint battles_completed_requires_resolution CHECK (((state <> 'completed'::text) OR (resolution_type IS NOT NULL)));

alter table battles add constraint battles_min_duration CHECK ((duration_ms >= 15000));

alter table battles add constraint battles_pkey PRIMARY KEY (id);

alter table battles add constraint battles_resolution_type_check CHECK ((resolution_type = ANY (ARRAY['normal'::text, 'sudden_death'::text, 'draw'::text, 'cancelled'::text, 'fit'::text])));

alter table battles add constraint battles_sd_no_winner CHECK (((sudden_death_active = false) OR (winner_song_id IS NULL)));

alter table battles add constraint battles_sd_not_completed CHECK (((sudden_death_active = false) OR (state <> 'completed'::text)));

alter table battles add constraint battles_sd_requires_started_at CHECK (((sudden_death_active = false) OR (sudden_death_started_at IS NOT NULL)));

alter table battles add constraint battles_soundtrack_check CHECK ((soundtrack = ANY (ARRAY['arena'::text, 'autoplay'::text])));

alter table battles add constraint battles_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'active'::text, 'closing'::text, 'completed'::text])));

alter table cron_seconds_test_log add constraint cron_seconds_test_log_pkey PRIMARY KEY (id);

alter table hosts add constraint hosts_pkey PRIMARY KEY (id);

alter table matchmaking_config add constraint matchmaking_config_id_check CHECK ((id = 1));

alter table matchmaking_config add constraint matchmaking_config_pkey PRIMARY KEY (id);

alter table matchmaking_log add constraint matchmaking_log_pkey PRIMARY KEY (id);

alter table mb_artists add constraint mb_artists_pkey PRIMARY KEY (mbid);

alter table mb_artists add constraint mb_artists_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'found'::text, 'not_found'::text, 'error'::text, 'failed'::text])));

alter table mb_enrich_state add constraint mb_enrich_state_id_check CHECK ((id = 1));

alter table mb_enrich_state add constraint mb_enrich_state_pkey PRIMARY KEY (id);

alter table mb_genres add constraint mb_genres_pkey PRIMARY KEY (name);

alter table participants add constraint participants_pkey PRIMARY KEY (id);

alter table participants add constraint unique_participant_per_arena UNIQUE (arena_id, identity_anchor_id);

alter table passive_vote_config add constraint passive_vote_config_id_check CHECK ((id = 1));

alter table passive_vote_config add constraint passive_vote_config_pkey PRIMARY KEY (id);

alter table pi_config add constraint pi_config_id_check CHECK (id);

alter table pi_config add constraint pi_config_pkey PRIMARY KEY (id);

alter table pi_ledger add constraint pi_ledger_event_unique UNIQUE NULLS NOT DISTINCT (user_id, battle_id, song_id, reason);

alter table pi_ledger add constraint pi_ledger_pkey PRIMARY KEY (id);

alter table pi_ledger add constraint pi_ledger_reason_check CHECK ((reason = ANY (ARRAY['battle_entry'::text, 'win'::text, 'tie'::text, 'sudden_death_bonus'::text, 'duplicate_half'::text, 'penalty'::text])));

alter table playback_events add constraint playback_events_pkey PRIMARY KEY (id);

alter table playlist_queue add constraint playlist_queue_pkey PRIMARY KEY (id);

alter table privacy_consents add constraint privacy_consents_pkey PRIMARY KEY (user_id);

alter table proposal_history add constraint proposal_history_backing_source_check CHECK ((backing_source = ANY (ARRAY['duplicate'::text, 'list'::text])));

alter table proposal_history add constraint proposal_history_kind_check CHECK ((kind = ANY (ARRAY['proposal'::text, 'backing'::text])));

alter table proposal_history add constraint proposal_history_outcome_check CHECK ((outcome = ANY (ARRAY['battled'::text, 'purged'::text, 'withdrawn'::text, 'removed'::text])));

alter table proposal_history add constraint proposal_history_pkey PRIMARY KEY (id);

alter table queue_backers add constraint queue_backers_pkey PRIMARY KEY (arena_id, song_id, user_id);

alter table queue_backers add constraint queue_backers_source_check CHECK ((source = ANY (ARRAY['duplicate'::text, 'list'::text])));

alter table queues add constraint queues_arena_song_unique UNIQUE (arena_id, song_id);

alter table queues add constraint queues_pkey PRIMARY KEY (id);

alter table queues add constraint queues_queue_type_check CHECK ((queue_type = ANY (ARRAY['waiting'::text, 'active'::text])));

alter table recordings add constraint recordings_pkey PRIMARY KEY (isrc);

alter table recordings add constraint recordings_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'found'::text, 'not_found'::text, 'error'::text, 'failed'::text])));

alter table song_likes add constraint song_likes_pkey PRIMARY KEY (id);

alter table song_likes add constraint song_likes_unique UNIQUE (arena_id, song_id, participant_id);

alter table songs add constraint songs_pkey PRIMARY KEY (id);

alter table songs add constraint songs_role_check CHECK ((role = ANY (ARRAY['competitor'::text, 'warmup'::text])));

alter table spotify_oauth_states add constraint spotify_oauth_states_pkey PRIMARY KEY (state);

alter table spotify_rate_limit add constraint spotify_rate_limit_id_check CHECK (id);

alter table spotify_rate_limit add constraint spotify_rate_limit_pkey PRIMARY KEY (id);

alter table streaming_accounts add constraint streaming_accounts_host_id_provider_key UNIQUE (host_id, provider);

alter table streaming_accounts add constraint streaming_accounts_pkey PRIMARY KEY (id);

alter table streaming_accounts add constraint streaming_accounts_premium_status_check CHECK ((premium_status = ANY (ARRAY['unverified'::text, 'premium'::text, 'not_premium'::text])));

alter table streaming_accounts add constraint streaming_accounts_provider_check CHECK ((provider = 'spotify'::text));

alter table system_song_config add constraint system_song_config_id_check CHECK ((id = 1));

alter table system_song_config add constraint system_song_config_pkey PRIMARY KEY (id);

alter table user_profiles add constraint user_profiles_country_check CHECK (((country IS NULL) OR (country ~ '^[A-Z]{2}$'::text)));

alter table user_profiles add constraint user_profiles_nickname_check CHECK (((nickname IS NULL) OR ((char_length(nickname) >= 2) AND (char_length(nickname) <= 20))));

alter table user_profiles add constraint user_profiles_pkey PRIMARY KEY (user_id);

alter table votes add constraint vote_type_allowed CHECK ((vote_type = ANY (ARRAY['regular'::text, 'passive'::text, 'sudden_death'::text])));

alter table votes add constraint votes_pkey PRIMARY KEY (id);

alter table votes add constraint votes_status_check CHECK ((status = ANY (ARRAY['active'::text, 'cancelled'::text])));

alter table account_merge_tickets add constraint account_merge_tickets_anon_user_id_fkey FOREIGN KEY (anon_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table affinity_signals add constraint affinity_signals_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE SET NULL;

alter table affinity_signals add constraint affinity_signals_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table arena_library_contributors add constraint arena_library_contributors_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table arena_library_contributors add constraint arena_library_contributors_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table arena_pi_standings add constraint arena_pi_standings_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table arena_pi_standings add constraint arena_pi_standings_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table arena_playback add constraint arena_playback_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table arena_playback add constraint arena_playback_host_id_fkey FOREIGN KEY (host_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table arena_song_reserve add constraint arena_song_reserve_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table arena_song_reserve add constraint arena_song_reserve_contributed_by_fkey FOREIGN KEY (contributed_by) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table arena_song_reserve add constraint arena_song_reserve_song_id_fkey FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE;

alter table arenas add constraint arenas_warmup_song_id_fkey FOREIGN KEY (warmup_song_id) REFERENCES songs(id) ON DELETE SET NULL;

alter table battle_presence_snapshots add constraint battle_presence_snapshots_battle_id_fkey FOREIGN KEY (battle_id) REFERENCES battles(id) ON DELETE CASCADE;

alter table battle_presence_snapshots add constraint battle_presence_snapshots_participant_id_fkey FOREIGN KEY (participant_id) REFERENCES participants(id) ON DELETE CASCADE;

alter table battles add constraint battles_winner_song_fk FOREIGN KEY (winner_song_id) REFERENCES songs(id) ON DELETE SET NULL;

alter table matchmaking_log add constraint matchmaking_log_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table matchmaking_log add constraint matchmaking_log_battle_id_fkey FOREIGN KEY (battle_id) REFERENCES battles(id) ON DELETE SET NULL;

alter table pi_ledger add constraint pi_ledger_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table pi_ledger add constraint pi_ledger_battle_id_fkey FOREIGN KEY (battle_id) REFERENCES battles(id) ON DELETE CASCADE;

alter table pi_ledger add constraint pi_ledger_song_id_fkey FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE SET NULL;

alter table pi_ledger add constraint pi_ledger_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table playback_events add constraint playback_events_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table playlist_queue add constraint playlist_queue_arena_fk FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table playlist_queue add constraint playlist_queue_battle_fk FOREIGN KEY (battle_id) REFERENCES battles(id) ON DELETE CASCADE;

alter table playlist_queue add constraint playlist_queue_winner_song_fk FOREIGN KEY (winner_song_id) REFERENCES songs(id) ON DELETE RESTRICT;

alter table privacy_consents add constraint privacy_consents_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table proposal_history add constraint proposal_history_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table proposal_history add constraint proposal_history_battle_id_fkey FOREIGN KEY (battle_id) REFERENCES battles(id) ON DELETE CASCADE;

alter table proposal_history add constraint proposal_history_song_id_fkey FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE;

alter table queue_backers add constraint queue_backers_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table queue_backers add constraint queue_backers_song_id_fkey FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE;

alter table queue_backers add constraint queue_backers_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table song_likes add constraint song_likes_arena_id_fkey FOREIGN KEY (arena_id) REFERENCES arenas(id) ON DELETE CASCADE;

alter table song_likes add constraint song_likes_participant_id_fkey FOREIGN KEY (participant_id) REFERENCES participants(id) ON DELETE CASCADE;

alter table song_likes add constraint song_likes_song_id_fkey FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE;

alter table spotify_oauth_states add constraint spotify_oauth_states_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table streaming_accounts add constraint streaming_accounts_host_id_fkey FOREIGN KEY (host_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table user_profiles add constraint user_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE INDEX affinity_signals_arena_idx ON public.affinity_signals USING btree (arena_id);

CREATE INDEX affinity_signals_user_idx ON public.affinity_signals USING btree (user_id);

CREATE INDEX arena_pi_standings_arena_idx ON public.arena_pi_standings USING btree (arena_id);

CREATE INDEX arena_pi_standings_user_idx ON public.arena_pi_standings USING btree (user_id);

CREATE UNIQUE INDEX arenas_arena_code_unique ON public.arenas USING btree (arena_code);

CREATE UNIQUE INDEX battles_one_live_battle_per_arena ON public.battles USING btree (arena_id) WHERE (state = ANY (ARRAY['pending'::text, 'active'::text]));

CREATE UNIQUE INDEX battles_vote_token_unique ON public.battles USING btree (vote_token);

CREATE INDEX idx_battles_enqueue_done ON public.battles USING btree (enqueue_done);

CREATE INDEX idx_battles_winner_song_id ON public.battles USING btree (winner_song_id);

CREATE INDEX matchmaking_log_arena_idx ON public.matchmaking_log USING btree (arena_id, created_at);

CREATE INDEX matchmaking_log_created_idx ON public.matchmaking_log USING btree (created_at);

CREATE INDEX mb_artists_aux_idx ON public.mb_artists USING btree (aux_next_at) WHERE (aux_step = 'lb_similar'::text);

CREATE INDEX pi_ledger_arena_idx ON public.pi_ledger USING btree (arena_id, user_id);

CREATE INDEX pi_ledger_created_idx ON public.pi_ledger USING btree (created_at);

CREATE INDEX playback_events_arena_at_idx ON public.playback_events USING btree (arena_id, at);

CREATE INDEX playlist_queue_arena_idx ON public.playlist_queue USING btree (arena_id);

CREATE INDEX playlist_queue_arena_track_idx ON public.playlist_queue USING btree (arena_id, spotify_track_id, created_at);

CREATE INDEX playlist_queue_created_at_idx ON public.playlist_queue USING btree (created_at);

CREATE INDEX playlist_queue_spotify_track_idx ON public.playlist_queue USING btree (spotify_track_id);

CREATE INDEX proposal_history_arena_proposer_idx ON public.proposal_history USING btree (arena_id, proposed_by);

CREATE INDEX proposal_history_battle_idx ON public.proposal_history USING btree (battle_id);

CREATE INDEX queue_backers_user_idx ON public.queue_backers USING btree (arena_id, user_id);

CREATE INDEX queues_arena_proposed_by_idx ON public.queues USING btree (arena_id, proposed_by);

CREATE INDEX recordings_aux_idx ON public.recordings USING btree (aux_next_at) WHERE (aux_step = ANY (ARRAY['search'::text, 'lb_tags'::text]));

CREATE INDEX songs_isrc_idx ON public.songs USING btree (isrc) WHERE (isrc IS NOT NULL);

CREATE UNIQUE INDEX songs_unique_per_arena ON public.songs USING btree (arena_id, source, spotify_track_id, role);

CREATE INDEX spotify_oauth_states_user_idx ON public.spotify_oauth_states USING btree (user_id);

CREATE INDEX user_profiles_country_idx ON public.user_profiles USING btree (country);

CREATE UNIQUE INDEX uniq_active_vote_per_battle_participant ON public.votes USING btree (battle_id, participant_id) WHERE (status = 'active'::text);

CREATE UNIQUE INDEX votes_one_active_per_participant ON public.votes USING btree (battle_id, participant_id) WHERE (status = 'active'::text);

CREATE UNIQUE INDEX votes_unique_participant_battle ON public.votes USING btree (battle_id, participant_id);
