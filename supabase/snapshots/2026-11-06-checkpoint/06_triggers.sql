CREATE TRIGGER trg_arenas_clear_reserve AFTER UPDATE OF state ON arenas FOR EACH ROW WHEN ((new.state = ANY (ARRAY['finished'::text, 'expired'::text])) AND old.state IS DISTINCT FROM new.state) EXECUTE FUNCTION clear_reserve_on_arena_end();

CREATE TRIGGER trg_arenas_touch_activity_on_start AFTER UPDATE OF state ON arenas FOR EACH ROW WHEN (old.state = 'waiting'::text AND new.state = 'active'::text) EXECUTE FUNCTION touch_activity_on_arena_start();

CREATE TRIGGER trg_battle_requires_active_arena BEFORE INSERT ON battles FOR EACH ROW EXECUTE FUNCTION enforce_battle_arena_active();

CREATE TRIGGER trg_battles_affinity_signals AFTER UPDATE OF state ON battles FOR EACH ROW WHEN (new.state = 'completed'::text AND old.state IS DISTINCT FROM 'completed'::text) EXECUTE FUNCTION signal_on_battle_completed();

CREATE TRIGGER trg_battles_apply_preassigned AFTER INSERT ON battles FOR EACH ROW EXECUTE FUNCTION apply_preassigned_votes();

CREATE TRIGGER trg_battles_link_proposals AFTER INSERT ON battles FOR EACH ROW EXECUTE FUNCTION link_battle_proposals();

CREATE TRIGGER trg_battles_nudge_autoplay AFTER UPDATE OF state ON battles FOR EACH ROW WHEN (new.state = 'active'::text AND old.state = 'pending'::text AND new.soundtrack = 'autoplay'::text) EXECUTE FUNCTION nudge_on_battle_change();

CREATE TRIGGER trg_battles_nudge_completed AFTER UPDATE OF state ON battles FOR EACH ROW WHEN (new.state = 'completed'::text AND old.state IS DISTINCT FROM 'completed'::text AND new.resolution_type IS DISTINCT FROM 'cancelled'::text) EXECUTE FUNCTION nudge_on_battle_change();

CREATE TRIGGER trg_battles_pi_awards AFTER UPDATE OF state ON battles FOR EACH ROW WHEN (new.state = 'completed'::text AND old.state IS DISTINCT FROM 'completed'::text) EXECUTE FUNCTION pi_on_battle_completed();

CREATE TRIGGER trg_battles_pi_entry AFTER INSERT ON battles FOR EACH ROW EXECUTE FUNCTION pi_on_battle_created();

CREATE TRIGGER trg_battles_reject_warmup BEFORE INSERT OR UPDATE OF song_a_id, song_b_id, winner_song_id ON battles FOR EACH ROW EXECUTE FUNCTION reject_warmup_song();

CREATE TRIGGER trg_battles_snapshot_presence AFTER UPDATE OF lockin_at ON battles FOR EACH ROW WHEN (old.lockin_at IS NULL AND new.lockin_at IS NOT NULL) EXECUTE FUNCTION snapshot_presence_at_lockin();

CREATE TRIGGER trg_participants_guard_presence BEFORE INSERT OR UPDATE ON participants FOR EACH ROW EXECUTE FUNCTION guard_participant_presence();

CREATE TRIGGER trg_playlist_queue_nudge AFTER INSERT ON playlist_queue REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION nudge_on_playlist_insert();

CREATE TRIGGER trg_queues_affinity_signal AFTER INSERT ON queues FOR EACH ROW EXECUTE FUNCTION signal_on_proposal();

CREATE TRIGGER trg_queues_reject_warmup BEFORE INSERT OR UPDATE OF song_id ON queues FOR EACH ROW EXECUTE FUNCTION reject_warmup_song();

CREATE TRIGGER trg_queues_stamp_proposer BEFORE INSERT ON queues FOR EACH ROW EXECUTE FUNCTION stamp_queue_proposer();

CREATE TRIGGER trg_queues_touch_activity AFTER INSERT ON queues FOR EACH ROW EXECUTE FUNCTION touch_activity_on_proposal();

CREATE TRIGGER trg_queues_validate BEFORE INSERT ON queues FOR EACH ROW EXECUTE FUNCTION validate_queue_proposal();

CREATE TRIGGER trg_songs_queue_recording AFTER INSERT OR UPDATE OF isrc ON songs FOR EACH ROW EXECUTE FUNCTION queue_recording_lookup();

CREATE TRIGGER trg_fill_vote_fields BEFORE INSERT ON votes FOR EACH ROW EXECUTE FUNCTION fill_vote_fields();

CREATE TRIGGER trg_votes_clear_preassigned BEFORE UPDATE ON votes FOR EACH ROW EXECUTE FUNCTION clear_vote_preassigned();

CREATE TRIGGER trg_votes_touch_activity AFTER INSERT OR UPDATE ON votes FOR EACH ROW EXECUTE FUNCTION touch_activity_on_vote();
