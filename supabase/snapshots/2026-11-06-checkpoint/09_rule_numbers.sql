insert into public.passive_vote_config select * from json_populate_record(null::public.passive_vote_config, $json${"id":1,"min_score":0.7,"base_value":0.4,"boosted_value":0.5,"value_span":0.1,"boost_passive_ratio":0.75,"k_cap":1.25,"ramp_seconds":30,"min_signals":3,"half_life_days":365,"top_tags":10,"score_same_song":1,"score_same_artist":0.9,"score_related_artist":0.75,"score_tags_cap":0.85,"weight_like":1,"weight_proposal":1,"weight_vote":0.5}$json$) on conflict do nothing;

insert into public.matchmaking_config select * from json_populate_record(null::public.matchmaking_config, $json${"id":1,"continuity_weight":0.6,"pair_weight":0.4,"taste_weight":0.1,"turn_weight":0.15,"neutral_compat":0.35,"max_skips":3,"log_retention_days":30,"votes_weight":2,"list_vote_limit":3,"duplicate_limit":5}$json$) on conflict do nothing;

insert into public.pi_config select * from json_populate_record(null::public.pi_config, $json${"id":true,"win":10,"sudden_death_bonus":5,"tie":5,"battle_entry":1,"backing_share":0.5,"entry_min_present":2}$json$) on conflict do nothing;

insert into public.system_song_config select * from json_populate_record(null::public.system_song_config, $json${"id":1,"style_half_life_minutes":60,"fit_bucket":0.1,"host_library_pool":8,"guest_library_pool":4,"arena_artist_pool":3,"rotate_every_minutes":5,"rotate_min_age_minutes":10}$json$) on conflict do nothing;
