grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.account_merge_tickets to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.affinity_signals to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.arena_library_contributors to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.arena_live_state to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.arena_live_state to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.arena_live_state to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.arena_pi_standings to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.arena_playback to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.arena_song_reserve to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.arenas to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.arenas to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.arenas to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER on public.battle_presence_snapshots to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER on public.battle_presence_snapshots to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.battle_presence_snapshots to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.battles to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.battles to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.battles to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.cron_debug_log to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.cron_seconds_test_log to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.hosts to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.hosts to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.hosts to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.matchmaking_config to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.matchmaking_log to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.mb_artists to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.mb_enrich_state to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.mb_genres to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.participant_presence to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.participant_presence to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.participant_presence to service_role;

grant INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.participants to anon;

grant INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.participants to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.participants to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.passive_vote_config to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.pi_config to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.pi_ledger to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.playback_events to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.playlist_queue to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.privacy_consents to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.proposal_history to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.queue_backers to service_role;

grant INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.queues to anon;

grant INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.queues to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.queues to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.recordings to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.song_likes to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.song_likes to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.song_likes to service_role;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.songs to anon;

grant MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE on public.songs to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.songs to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.spotify_oauth_states to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.spotify_rate_limit to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.streaming_accounts to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.system_song_config to service_role;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.user_profiles to service_role;

grant INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.votes to anon;

grant INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.votes to authenticated;

grant DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on public.votes to service_role;

revoke all on function public.add_reserve_songs(p_arena_id uuid, p_source text, p_tracks jsonb, p_limit integer, p_contributor uuid) from public, anon, authenticated;
grant execute on function public.add_reserve_songs(p_arena_id uuid, p_source text, p_tracks jsonb, p_limit integer, p_contributor uuid) to service_role;

revoke all on function public.adjust_battle_duration(p_battle_id uuid, p_delta_ms integer) from public, anon, authenticated;
grant execute on function public.adjust_battle_duration(p_battle_id uuid, p_delta_ms integer) to service_role;

revoke all on function public.affinity_score(p_user uuid, p_isrc text, p_arena uuid) from public, anon, authenticated;
grant execute on function public.affinity_score(p_user uuid, p_isrc text, p_arena uuid) to service_role;

revoke all on function public.apply_preassigned_votes() from public, anon, authenticated;
grant execute on function public.apply_preassigned_votes() to service_role;

revoke all on function public.arena_fit_winner(p_battle_id uuid) from public, anon, authenticated;
grant execute on function public.arena_fit_winner(p_battle_id uuid) to service_role;

revoke all on function public.arena_last_activity(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.arena_last_activity(p_arena_id uuid) to service_role;

revoke all on function public.arena_next_up(p_arena_id uuid, p_viewer uuid) from public, anon, authenticated;
grant execute on function public.arena_next_up(p_arena_id uuid, p_viewer uuid) to service_role;

revoke all on function public.arena_pi_ranking(p_arena_id uuid, p_viewer uuid) from public, anon, authenticated;
grant execute on function public.arena_pi_ranking(p_arena_id uuid, p_viewer uuid) to service_role;

revoke all on function public.arena_playback_plan(p_arena_id uuid, p_at timestamp with time zone) from public, anon, authenticated;
grant execute on function public.arena_playback_plan(p_arena_id uuid, p_at timestamp with time zone) to service_role;

revoke all on function public.arena_playback_state(p_arena_id uuid, p_viewer uuid) from public, anon, authenticated;
grant execute on function public.arena_playback_state(p_arena_id uuid, p_viewer uuid) to service_role;

revoke all on function public.arena_sound_plan(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.arena_sound_plan(p_arena_id uuid) to service_role;

revoke all on function public.arena_style_songs(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.arena_style_songs(p_arena_id uuid) to service_role;

revoke all on function public.autoplay_lead_in(p_arena_id uuid, p_track_uri text, p_track_started_at timestamp with time zone, p_track_ends_at timestamp with time zone) from public, anon, authenticated;
grant execute on function public.autoplay_lead_in(p_arena_id uuid, p_track_uri text, p_track_started_at timestamp with time zone, p_track_ends_at timestamp with time zone) to service_role;

revoke all on function public.award_pi(p_user uuid, p_arena uuid, p_battle uuid, p_song uuid, p_reason text, p_delta integer) from public, anon, authenticated;
grant execute on function public.award_pi(p_user uuid, p_arena uuid, p_battle uuid, p_song uuid, p_reason text, p_delta integer) to service_role;

revoke all on function public.back_proposal(p_arena_id uuid, p_song_id uuid, p_source text) from public, anon, authenticated;
grant execute on function public.back_proposal(p_arena_id uuid, p_song_id uuid, p_source text) to authenticated;
grant execute on function public.back_proposal(p_arena_id uuid, p_song_id uuid, p_source text) to service_role;

revoke all on function public.battle_over_entry(p_arena_id uuid, p_entry_battle_id uuid) from public, anon, authenticated;
grant execute on function public.battle_over_entry(p_arena_id uuid, p_entry_battle_id uuid) to service_role;

revoke all on function public.battle_passive_tally(p_battle_id uuid) from public, anon, authenticated;
grant execute on function public.battle_passive_tally(p_battle_id uuid) to anon;
grant execute on function public.battle_passive_tally(p_battle_id uuid) to authenticated;
grant execute on function public.battle_passive_tally(p_battle_id uuid) to service_role;

revoke all on function public.begin_playback_check(p_arena_id uuid, p_min_ms integer) from public, anon, authenticated;
grant execute on function public.begin_playback_check(p_arena_id uuid, p_min_ms integer) to service_role;

revoke all on function public.calculate_lockin_vote_totals(p_battle_id uuid) from public, anon, authenticated;
grant execute on function public.calculate_lockin_vote_totals(p_battle_id uuid) to service_role;

revoke all on function public.can_read_warmup_audio(p_object_name text) from public, anon, authenticated;
grant execute on function public.can_read_warmup_audio(p_object_name text) to anon;
grant execute on function public.can_read_warmup_audio(p_object_name text) to authenticated;
grant execute on function public.can_read_warmup_audio(p_object_name text) to service_role;

revoke all on function public.cast_passive_votes(p_battle_id uuid) from public, anon, authenticated;
grant execute on function public.cast_passive_votes(p_battle_id uuid) to service_role;

revoke all on function public.cast_vote_if_none(p_arena_id uuid, p_song_id uuid, p_participant uuid) from public, anon, authenticated;
grant execute on function public.cast_vote_if_none(p_arena_id uuid, p_song_id uuid, p_participant uuid) to service_role;

revoke all on function public.claim_playlist_appends(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.claim_playlist_appends(p_arena_id uuid) to service_role;

revoke all on function public.clear_reserve_on_arena_end() from public, anon, authenticated;
grant execute on function public.clear_reserve_on_arena_end() to anon;
grant execute on function public.clear_reserve_on_arena_end() to authenticated;
grant execute on function public.clear_reserve_on_arena_end() to service_role;

revoke all on function public.clear_vote_preassigned() from public, anon, authenticated;
grant execute on function public.clear_vote_preassigned() to anon;
grant execute on function public.clear_vote_preassigned() to authenticated;
grant execute on function public.clear_vote_preassigned() to service_role;

revoke all on function public.close_open_battles(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.close_open_battles(p_arena_id uuid) to service_role;

revoke all on function public.correct_track_duration(p_arena_id uuid, p_track_uri text, p_duration_ms integer) from public, anon, authenticated;
grant execute on function public.correct_track_duration(p_arena_id uuid, p_track_uri text, p_duration_ms integer) to service_role;

revoke all on function public.create_arena_spotify(p_host_id uuid, p_name text, p_mood text, p_track jsonb) from public, anon, authenticated;
grant execute on function public.create_arena_spotify(p_host_id uuid, p_name text, p_mood text, p_track jsonb) to service_role;

revoke all on function public.create_merge_ticket() from public, anon, authenticated;
grant execute on function public.create_merge_ticket() to authenticated;
grant execute on function public.create_merge_ticket() to service_role;

revoke all on function public.create_next_battle(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.create_next_battle(p_arena_id uuid) to service_role;

revoke all on function public.delete_song_if_unused(p_song_id uuid) from public, anon, authenticated;
grant execute on function public.delete_song_if_unused(p_song_id uuid) to service_role;

revoke all on function public.drop_queue_backers(p_arena_id uuid, p_song_ids uuid[], p_outcome text) from public, anon, authenticated;
grant execute on function public.drop_queue_backers(p_arena_id uuid, p_song_ids uuid[], p_outcome text) to service_role;

revoke all on function public.drop_reserve_rows(p_arena_id uuid, p_contributor uuid) from public, anon, authenticated;
grant execute on function public.drop_reserve_rows(p_arena_id uuid, p_contributor uuid) to service_role;

revoke all on function public.end_arena(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.end_arena(p_arena_id uuid) to authenticated;
grant execute on function public.end_arena(p_arena_id uuid) to service_role;

revoke all on function public.enforce_battle_arena_active() from public, anon, authenticated;
grant execute on function public.enforce_battle_arena_active() to anon;
grant execute on function public.enforce_battle_arena_active() to authenticated;
grant execute on function public.enforce_battle_arena_active() to service_role;

revoke all on function public.ensure_mock_songs_for_arena(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.ensure_mock_songs_for_arena(p_arena_id uuid) to service_role;

revoke all on function public.enter_arena(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.enter_arena(p_arena_id uuid) to authenticated;
grant execute on function public.enter_arena(p_arena_id uuid) to service_role;

revoke all on function public.expire_stale_arenas(p_waiting_idle interval, p_active_idle interval) from public, anon, authenticated;
grant execute on function public.expire_stale_arenas(p_waiting_idle interval, p_active_idle interval) to service_role;

revoke all on function public.fallback_candidate(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid, p_partner_isrc text, p_ref_isrc text, p_has_partner boolean) from public, anon, authenticated;
grant execute on function public.fallback_candidate(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid, p_partner_isrc text, p_ref_isrc text, p_has_partner boolean) to service_role;

revoke all on function public.fill_song_like_fields() from public, anon, authenticated;
grant execute on function public.fill_song_like_fields() to anon;
grant execute on function public.fill_song_like_fields() to authenticated;
grant execute on function public.fill_song_like_fields() to service_role;

revoke all on function public.fill_vote_fields() from public, anon, authenticated;
grant execute on function public.fill_vote_fields() to anon;
grant execute on function public.fill_vote_fields() to authenticated;
grant execute on function public.fill_vote_fields() to service_role;

revoke all on function public.finish_arena(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.finish_arena(p_arena_id uuid) to service_role;

revoke all on function public.fit_battle_to_track(p_arena_id uuid, p_track_ends_at timestamp with time zone) from public, anon, authenticated;
grant execute on function public.fit_battle_to_track(p_arena_id uuid, p_track_ends_at timestamp with time zone) to service_role;

revoke all on function public.forget_host_spotify(p_host_id uuid) from public, anon, authenticated;
grant execute on function public.forget_host_spotify(p_host_id uuid) to service_role;

revoke all on function public.generate_arena_code() from public, anon, authenticated;
grant execute on function public.generate_arena_code() to anon;
grant execute on function public.generate_arena_code() to authenticated;
grant execute on function public.generate_arena_code() to service_role;

revoke all on function public.get_arena_next_up(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_arena_next_up(p_arena_id uuid) to authenticated;
grant execute on function public.get_arena_next_up(p_arena_id uuid) to service_role;

revoke all on function public.get_arena_pi_leaderboard(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_arena_pi_leaderboard(p_arena_id uuid) to authenticated;
grant execute on function public.get_arena_pi_leaderboard(p_arena_id uuid) to service_role;

revoke all on function public.get_arena_playback(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_arena_playback(p_arena_id uuid) to authenticated;
grant execute on function public.get_arena_playback(p_arena_id uuid) to service_role;

revoke all on function public.get_arena_presence(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_arena_presence(p_arena_id uuid) to authenticated;
grant execute on function public.get_arena_presence(p_arena_id uuid) to service_role;

revoke all on function public.get_arena_queue_summary(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_arena_queue_summary(p_arena_id uuid) to authenticated;
grant execute on function public.get_arena_queue_summary(p_arena_id uuid) to service_role;

revoke all on function public.get_arena_warmup(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_arena_warmup(p_arena_id uuid) to anon;
grant execute on function public.get_arena_warmup(p_arena_id uuid) to authenticated;
grant execute on function public.get_arena_warmup(p_arena_id uuid) to service_role;

revoke all on function public.get_current_arena() from public, anon, authenticated;
grant execute on function public.get_current_arena() to authenticated;
grant execute on function public.get_current_arena() to service_role;

revoke all on function public.get_my_passive_vote(p_battle_id uuid) from public, anon, authenticated;
grant execute on function public.get_my_passive_vote(p_battle_id uuid) to authenticated;
grant execute on function public.get_my_passive_vote(p_battle_id uuid) to service_role;

revoke all on function public.get_my_past_arenas(p_limit integer) from public, anon, authenticated;
grant execute on function public.get_my_past_arenas(p_limit integer) to authenticated;
grant execute on function public.get_my_past_arenas(p_limit integer) to service_role;

revoke all on function public.get_my_pi(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_my_pi(p_arena_id uuid) to authenticated;
grant execute on function public.get_my_pi(p_arena_id uuid) to service_role;

revoke all on function public.get_my_profile() from public, anon, authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.get_my_profile() to service_role;

revoke all on function public.get_my_proposals(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_my_proposals(p_arena_id uuid) to authenticated;
grant execute on function public.get_my_proposals(p_arena_id uuid) to service_role;

revoke all on function public.get_my_song_likes(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.get_my_song_likes(p_arena_id uuid) to authenticated;
grant execute on function public.get_my_song_likes(p_arena_id uuid) to service_role;

revoke all on function public.get_my_streaming_connection() from public, anon, authenticated;
grant execute on function public.get_my_streaming_connection() to authenticated;
grant execute on function public.get_my_streaming_connection() to service_role;

revoke all on function public.get_pi_leaderboard(p_scope text, p_period text, p_country text, p_limit integer) from public, anon, authenticated;
grant execute on function public.get_pi_leaderboard(p_scope text, p_period text, p_country text, p_limit integer) to authenticated;
grant execute on function public.get_pi_leaderboard(p_scope text, p_period text, p_country text, p_limit integer) to service_role;

revoke all on function public.get_stage_view(p_code text) from public, anon, authenticated;
grant execute on function public.get_stage_view(p_code text) to authenticated;
grant execute on function public.get_stage_view(p_code text) to service_role;

revoke all on function public.guard_participant_presence() from public, anon, authenticated;
grant execute on function public.guard_participant_presence() to anon;
grant execute on function public.guard_participant_presence() to authenticated;
grant execute on function public.guard_participant_presence() to service_role;

revoke all on function public.leave_arena(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.leave_arena(p_arena_id uuid) to authenticated;
grant execute on function public.leave_arena(p_arena_id uuid) to service_role;

revoke all on function public.library_arena_id() from public, anon, authenticated;
grant execute on function public.library_arena_id() to anon;
grant execute on function public.library_arena_id() to authenticated;
grant execute on function public.library_arena_id() to service_role;

revoke all on function public.link_battle_proposals() from public, anon, authenticated;
grant execute on function public.link_battle_proposals() to anon;
grant execute on function public.link_battle_proposals() to authenticated;
grant execute on function public.link_battle_proposals() to service_role;

revoke all on function public.lock_arena_queue(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.lock_arena_queue(p_arena_id uuid) to service_role;

revoke all on function public.log_playback_event(p_arena_id uuid, p_kind text, p_detail jsonb) from public, anon, authenticated;
grant execute on function public.log_playback_event(p_arena_id uuid, p_kind text, p_detail jsonb) to service_role;

revoke all on function public.mark_like_saved_to_spotify(p_user uuid, p_arena_id uuid, p_song_id uuid) from public, anon, authenticated;
grant execute on function public.mark_like_saved_to_spotify(p_user uuid, p_arena_id uuid, p_song_id uuid) to service_role;

revoke all on function public.mark_playlist_appended(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.mark_playlist_appended(p_arena_id uuid) to service_role;

revoke all on function public.matchmaking_plan(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.matchmaking_plan(p_arena_id uuid) to service_role;

revoke all on function public.matchmaking_ref_song(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.matchmaking_ref_song(p_arena_id uuid) to service_role;

revoke all on function public.matchmaking_song_score(p_song song_feature, p_partner song_feature, p_ref song_feature, p_has_partner boolean) from public, anon, authenticated;
grant execute on function public.matchmaking_song_score(p_song song_feature, p_partner song_feature, p_ref song_feature, p_has_partner boolean) to service_role;

revoke all on function public.mb_enrich_begin(p_seconds integer) from public, anon, authenticated;
grant execute on function public.mb_enrich_begin(p_seconds integer) to service_role;

revoke all on function public.mb_enrich_end() from public, anon, authenticated;
grant execute on function public.mb_enrich_end() to service_role;

revoke all on function public.mb_fail(p_kind text, p_key text) from public, anon, authenticated;
grant execute on function public.mb_fail(p_kind text, p_key text) to service_role;

revoke all on function public.mb_has_work() from public, anon, authenticated;
grant execute on function public.mb_has_work() to service_role;

revoke all on function public.mb_next_work(p_lb_only boolean) from public, anon, authenticated;
grant execute on function public.mb_next_work(p_lb_only boolean) to service_role;

revoke all on function public.mb_save_artist(p_mbid uuid, p_result jsonb) from public, anon, authenticated;
grant execute on function public.mb_save_artist(p_mbid uuid, p_result jsonb) to service_role;

revoke all on function public.mb_save_genres(p_names text[]) from public, anon, authenticated;
grant execute on function public.mb_save_genres(p_names text[]) to service_role;

revoke all on function public.mb_save_lb_similar(p_mbid uuid, p_similar uuid[]) from public, anon, authenticated;
grant execute on function public.mb_save_lb_similar(p_mbid uuid, p_similar uuid[]) to service_role;

revoke all on function public.mb_save_lb_tags(p_isrc text, p_tags text[]) from public, anon, authenticated;
grant execute on function public.mb_save_lb_tags(p_isrc text, p_tags text[]) to service_role;

revoke all on function public.mb_save_recording(p_isrc text, p_result jsonb) from public, anon, authenticated;
grant execute on function public.mb_save_recording(p_isrc text, p_result jsonb) to service_role;

revoke all on function public.mb_save_search(p_isrc text, p_result jsonb) from public, anon, authenticated;
grant execute on function public.mb_save_search(p_isrc text, p_result jsonb) to service_role;

revoke all on function public.member_profile_candidate(p_arena_id uuid, p_exclude text[], p_avoid_proposer uuid, p_partner song_feature, p_ref song_feature, p_has_partner boolean, p_seed text) from public, anon, authenticated;
grant execute on function public.member_profile_candidate(p_arena_id uuid, p_exclude text[], p_avoid_proposer uuid, p_partner song_feature, p_ref song_feature, p_has_partner boolean, p_seed text) to service_role;

revoke all on function public.merge_anonymous_user(p_from uuid, p_to uuid) from public, anon, authenticated;
grant execute on function public.merge_anonymous_user(p_from uuid, p_to uuid) to service_role;

revoke all on function public.mf_display_name(p_user uuid) from public, anon, authenticated;
grant execute on function public.mf_display_name(p_user uuid) to service_role;

revoke all on function public.mf_generated_nickname(p_user uuid) from public, anon, authenticated;
grant execute on function public.mf_generated_nickname(p_user uuid) to anon;
grant execute on function public.mf_generated_nickname(p_user uuid) to authenticated;
grant execute on function public.mf_generated_nickname(p_user uuid) to service_role;

revoke all on function public.normalize_isrc(p text) from public, anon, authenticated;
grant execute on function public.normalize_isrc(p text) to anon;
grant execute on function public.normalize_isrc(p text) to authenticated;
grant execute on function public.normalize_isrc(p text) to service_role;

revoke all on function public.nudge_on_battle_change() from public, anon, authenticated;
grant execute on function public.nudge_on_battle_change() to service_role;

revoke all on function public.nudge_on_playlist_insert() from public, anon, authenticated;
grant execute on function public.nudge_on_playlist_insert() to service_role;

revoke all on function public.nudge_spotify_host(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.nudge_spotify_host(p_arena_id uuid) to service_role;

revoke all on function public.passive_vote_candidates(p_battle_id uuid, p_live boolean) from public, anon, authenticated;
grant execute on function public.passive_vote_candidates(p_battle_id uuid, p_live boolean) to service_role;

revoke all on function public.pause_arena(p_arena_id uuid, p_reason text) from public, anon, authenticated;
grant execute on function public.pause_arena(p_arena_id uuid, p_reason text) to service_role;

revoke all on function public.pi_on_battle_completed() from public, anon, authenticated;
grant execute on function public.pi_on_battle_completed() to anon;
grant execute on function public.pi_on_battle_completed() to authenticated;
grant execute on function public.pi_on_battle_completed() to service_role;

revoke all on function public.pi_on_battle_created() from public, anon, authenticated;
grant execute on function public.pi_on_battle_created() to anon;
grant execute on function public.pi_on_battle_created() to authenticated;
grant execute on function public.pi_on_battle_created() to service_role;

revoke all on function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid, p_partner_isrc text, p_ref_isrc text, p_has_partner boolean) from public, anon, authenticated;
grant execute on function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid, p_partner_isrc text, p_ref_isrc text, p_has_partner boolean) to service_role;

revoke all on function public.pick_rematch_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid, p_partner song_feature, p_ref song_feature, p_has_partner boolean) from public, anon, authenticated;
grant execute on function public.pick_rematch_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid, p_partner song_feature, p_ref song_feature, p_has_partner boolean) to service_role;

revoke all on function public.prepare_reserve(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.prepare_reserve(p_arena_id uuid) to service_role;

revoke all on function public.presence_disconnect() from public, anon, authenticated;
grant execute on function public.presence_disconnect() to authenticated;
grant execute on function public.presence_disconnect() to service_role;

revoke all on function public.presence_heartbeat() from public, anon, authenticated;
grant execute on function public.presence_heartbeat() to authenticated;
grant execute on function public.presence_heartbeat() to service_role;

revoke all on function public.presence_state(p_last_active_at timestamp with time zone, p_last_seen_at timestamp with time zone, p_disconnected_at timestamp with time zone, p_left_at timestamp with time zone, p_arena_state text, p_at timestamp with time zone) from public, anon, authenticated;
grant execute on function public.presence_state(p_last_active_at timestamp with time zone, p_last_seen_at timestamp with time zone, p_disconnected_at timestamp with time zone, p_left_at timestamp with time zone, p_arena_state text, p_at timestamp with time zone) to anon;
grant execute on function public.presence_state(p_last_active_at timestamp with time zone, p_last_seen_at timestamp with time zone, p_disconnected_at timestamp with time zone, p_left_at timestamp with time zone, p_arena_state text, p_at timestamp with time zone) to authenticated;
grant execute on function public.presence_state(p_last_active_at timestamp with time zone, p_last_seen_at timestamp with time zone, p_disconnected_at timestamp with time zone, p_left_at timestamp with time zone, p_arena_state text, p_at timestamp with time zone) to service_role;

revoke all on function public.presence_taste(p_arena_id uuid, p_isrc text) from public, anon, authenticated;
grant execute on function public.presence_taste(p_arena_id uuid, p_isrc text) to service_role;

revoke all on function public.process_battle_lifecycle(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.process_battle_lifecycle(p_arena_id uuid) to service_role;

revoke all on function public.pull_next_battle_songs(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.pull_next_battle_songs(p_arena_id uuid) to service_role;

revoke all on function public.purge_old_arena_votes(p_retention interval) from public, anon, authenticated;
grant execute on function public.purge_old_arena_votes(p_retention interval) to service_role;

revoke all on function public.queue_ranked(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.queue_ranked(p_arena_id uuid) to service_role;

revoke all on function public.queue_recording_lookup() from public, anon, authenticated;
grant execute on function public.queue_recording_lookup() to anon;
grant execute on function public.queue_recording_lookup() to authenticated;
grant execute on function public.queue_recording_lookup() to service_role;

revoke all on function public.record_affinity_signal(p_user uuid, p_song uuid, p_kind text, p_arena uuid) from public, anon, authenticated;
grant execute on function public.record_affinity_signal(p_user uuid, p_song uuid, p_kind text, p_arena uuid) to service_role;

revoke all on function public.record_privacy_consent(p_version text) from public, anon, authenticated;
grant execute on function public.record_privacy_consent(p_version text) to authenticated;
grant execute on function public.record_privacy_consent(p_version text) to service_role;

revoke all on function public.refill_active_queue(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.refill_active_queue(p_arena_id uuid) to service_role;

revoke all on function public.reject_warmup_song() from public, anon, authenticated;
grant execute on function public.reject_warmup_song() to anon;
grant execute on function public.reject_warmup_song() to authenticated;
grant execute on function public.reject_warmup_song() to service_role;

revoke all on function public.release_dead_system_votes(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.release_dead_system_votes(p_arena_id uuid) to service_role;

revoke all on function public.release_playlist_appends(p_ids uuid[]) from public, anon, authenticated;
grant execute on function public.release_playlist_appends(p_ids uuid[]) to service_role;

revoke all on function public.resolve_vote_token(p_token text, p_side text) from public, anon, authenticated;
grant execute on function public.resolve_vote_token(p_token text, p_side text) to authenticated;
grant execute on function public.resolve_vote_token(p_token text, p_side text) to service_role;

revoke all on function public.resume_arena(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.resume_arena(p_arena_id uuid) to service_role;

revoke all on function public.score_arena_reserve(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.score_arena_reserve(p_arena_id uuid) to service_role;

revoke all on function public.set_arena_control_mode(p_arena_id uuid, p_mode text) from public, anon, authenticated;
grant execute on function public.set_arena_control_mode(p_arena_id uuid, p_mode text) to authenticated;
grant execute on function public.set_arena_control_mode(p_arena_id uuid, p_mode text) to service_role;

revoke all on function public.set_library_contribution(p_arena_id uuid, p_user_id uuid, p_enabled boolean) from public, anon, authenticated;
grant execute on function public.set_library_contribution(p_arena_id uuid, p_user_id uuid, p_enabled boolean) to service_role;

revoke all on function public.shift_open_battle(p_battle_id uuid, p_shift interval, p_warmup boolean) from public, anon, authenticated;
grant execute on function public.shift_open_battle(p_battle_id uuid, p_shift interval, p_warmup boolean) to service_role;

revoke all on function public.signal_on_battle_completed() from public, anon, authenticated;
grant execute on function public.signal_on_battle_completed() to anon;
grant execute on function public.signal_on_battle_completed() to authenticated;
grant execute on function public.signal_on_battle_completed() to service_role;

revoke all on function public.signal_on_proposal() from public, anon, authenticated;
grant execute on function public.signal_on_proposal() to anon;
grant execute on function public.signal_on_proposal() to authenticated;
grant execute on function public.signal_on_proposal() to service_role;

revoke all on function public.skip_to_lockin(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.skip_to_lockin(p_arena_id uuid) to service_role;

revoke all on function public.skip_unplayable_track(p_arena_id uuid, p_track_uri text) from public, anon, authenticated;
grant execute on function public.skip_unplayable_track(p_arena_id uuid, p_track_uri text) to service_role;

revoke all on function public.snapshot_battle_presence(p_battle_id uuid, p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.snapshot_battle_presence(p_battle_id uuid, p_arena_id uuid) to service_role;

revoke all on function public.snapshot_presence_at_lockin() from public, anon, authenticated;
grant execute on function public.snapshot_presence_at_lockin() to anon;
grant execute on function public.snapshot_presence_at_lockin() to authenticated;
grant execute on function public.snapshot_presence_at_lockin() to service_role;

revoke all on function public.song_compat(a song_feature, b song_feature) from public, anon, authenticated;
grant execute on function public.song_compat(a song_feature, b song_feature) to service_role;

revoke all on function public.song_features(p_isrc text) from public, anon, authenticated;
grant execute on function public.song_features(p_isrc text) to service_role;

revoke all on function public.song_original_proposer(p_arena_id uuid, p_song_id uuid) from public, anon, authenticated;
grant execute on function public.song_original_proposer(p_arena_id uuid, p_song_id uuid) to service_role;

revoke all on function public.song_set_score(p_isrcs text[], p_ws real[], p_isrc text) from public, anon, authenticated;
grant execute on function public.song_set_score(p_isrcs text[], p_ws real[], p_isrc text) to service_role;

revoke all on function public.stage_view_song_credit(p_arena_id uuid, p_battle_id uuid, p_song_id uuid) from public, anon, authenticated;
grant execute on function public.stage_view_song_credit(p_arena_id uuid, p_battle_id uuid, p_song_id uuid) to service_role;

revoke all on function public.stamp_queue_proposer() from public, anon, authenticated;
grant execute on function public.stamp_queue_proposer() to anon;
grant execute on function public.stamp_queue_proposer() to authenticated;
grant execute on function public.stamp_queue_proposer() to service_role;

revoke all on function public.start_arena_battles(p_arena_id uuid) from public, anon, authenticated;
grant execute on function public.start_arena_battles(p_arena_id uuid) to anon;
grant execute on function public.start_arena_battles(p_arena_id uuid) to authenticated;
grant execute on function public.start_arena_battles(p_arena_id uuid) to service_role;

revoke all on function public.sync_arena_clock(p_arena_id uuid, p_track_uri text, p_track_started_at timestamp with time zone) from public, anon, authenticated;
grant execute on function public.sync_arena_clock(p_arena_id uuid, p_track_uri text, p_track_started_at timestamp with time zone) to service_role;

revoke all on function public.system_song_votable(p_arena_id uuid, p_song_id uuid) from public, anon, authenticated;
grant execute on function public.system_song_votable(p_arena_id uuid, p_song_id uuid) to service_role;

revoke all on function public.toggle_song_like(p_arena_id uuid, p_song_id uuid) from public, anon, authenticated;
grant execute on function public.toggle_song_like(p_arena_id uuid, p_song_id uuid) to authenticated;
grant execute on function public.toggle_song_like(p_arena_id uuid, p_song_id uuid) to service_role;

revoke all on function public.touch_activity_on_arena_start() from public, anon, authenticated;
grant execute on function public.touch_activity_on_arena_start() to anon;
grant execute on function public.touch_activity_on_arena_start() to authenticated;
grant execute on function public.touch_activity_on_arena_start() to service_role;

revoke all on function public.touch_activity_on_proposal() from public, anon, authenticated;
grant execute on function public.touch_activity_on_proposal() to anon;
grant execute on function public.touch_activity_on_proposal() to authenticated;
grant execute on function public.touch_activity_on_proposal() to service_role;

revoke all on function public.touch_activity_on_vote() from public, anon, authenticated;
grant execute on function public.touch_activity_on_vote() to anon;
grant execute on function public.touch_activity_on_vote() to authenticated;
grant execute on function public.touch_activity_on_vote() to service_role;

revoke all on function public.touch_participant_activity(p_arena_id uuid, p_uid uuid) from public, anon, authenticated;
grant execute on function public.touch_participant_activity(p_arena_id uuid, p_uid uuid) to service_role;

revoke all on function public.track_available_at(p_arena_id uuid, p_track text) from public, anon, authenticated;
grant execute on function public.track_available_at(p_arena_id uuid, p_track text) to anon;
grant execute on function public.track_available_at(p_arena_id uuid, p_track text) to authenticated;
grant execute on function public.track_available_at(p_arena_id uuid, p_track text) to service_role;

revoke all on function public.track_fought_in_arena(p_arena_id uuid, p_track text) from public, anon, authenticated;
grant execute on function public.track_fought_in_arena(p_arena_id uuid, p_track text) to service_role;

revoke all on function public.track_sounded_in_arena(p_arena_id uuid, p_track text, p_isrc text) from public, anon, authenticated;
grant execute on function public.track_sounded_in_arena(p_arena_id uuid, p_track text, p_isrc text) to service_role;

revoke all on function public.update_my_profile(p_nickname text, p_country text) from public, anon, authenticated;
grant execute on function public.update_my_profile(p_nickname text, p_country text) to authenticated;
grant execute on function public.update_my_profile(p_nickname text, p_country text) to service_role;

revoke all on function public.upsert_spotify_song(p_arena_id uuid, p_track jsonb) from public, anon, authenticated;
grant execute on function public.upsert_spotify_song(p_arena_id uuid, p_track jsonb) to service_role;

revoke all on function public.validate_queue_proposal() from public, anon, authenticated;
grant execute on function public.validate_queue_proposal() to anon;
grant execute on function public.validate_queue_proposal() to authenticated;
grant execute on function public.validate_queue_proposal() to service_role;

revoke all on function public.wake_spotify_host() from public, anon, authenticated;
grant execute on function public.wake_spotify_host() to service_role;

revoke all on function public.withdraw_backing(p_arena_id uuid, p_song_id uuid) from public, anon, authenticated;
grant execute on function public.withdraw_backing(p_arena_id uuid, p_song_id uuid) to authenticated;
grant execute on function public.withdraw_backing(p_arena_id uuid, p_song_id uuid) to service_role;

revoke all on function public.withdraw_proposal(p_queue_id uuid) from public, anon, authenticated;
grant execute on function public.withdraw_proposal(p_queue_id uuid) to authenticated;
grant execute on function public.withdraw_proposal(p_queue_id uuid) to service_role;
