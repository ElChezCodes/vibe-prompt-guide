select cron.schedule('arena_expiry_job', '*/15 * * * *', 'select public.expire_stale_arenas()');

select cron.schedule('arena_vote_purge_job', '0 4 * * *', 'select public.purge_old_arena_votes()');

select cron.schedule('battle_lifecycle_job', '1 second', '
  SELECT process_battle_lifecycle(a.id)
  FROM arenas a
  WHERE a.state = ''active''
    AND a.paused_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM battles b
      WHERE b.arena_id = a.id
        AND b.state IN (''pending'',''active'',''closing'')
    );
  SELECT create_next_battle(a.id)
  FROM arenas a
  WHERE a.state = ''active''
    AND a.paused_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM battles b
      WHERE b.arena_id = a.id
        AND b.state IN (''pending'',''active'',''closing'')
    );
  SELECT wake_spotify_host();
  ');

select cron.schedule('cron_log_retention', '*/10 * * * *', '
  delete from cron.job_run_details
  where (jobid in (select jobid from cron.job where jobname in (''battle_lifecycle_job'', ''spotify_playback_watch_job''))
         and end_time < now() - interval ''1 hour'')
     or end_time < now() - interval ''3 days'';
  ');

select cron.schedule('musicbrainz_enrich_job', '* * * * *', '
  select net.http_post(
    url := ''https://uuxzjroikbzwaszpgiks.supabase.co/functions/v1/musicbrainz-enrich'',
    headers := jsonb_build_object(
      ''Content-Type'', ''application/json'',
      ''x-watch-secret'', coalesce((select decrypted_secret from vault.decrypted_secrets where name = ''spotify_watch_secret''), '''')
    ),
    body := ''{}''::jsonb,
    timeout_milliseconds := 58000
  )
  where public.mb_has_work();
  ');

select cron.schedule('spotify_playback_watch_job', '15 seconds', '
  select net.http_post(
    url := ''https://uuxzjroikbzwaszpgiks.supabase.co/functions/v1/spotify-host'',
    headers := jsonb_build_object(
      ''Content-Type'', ''application/json'',
      ''x-watch-secret'', coalesce((select decrypted_secret from vault.decrypted_secrets where name = ''spotify_watch_secret''), '''')
    ),
    body := ''{"action":"watch"}''::jsonb,
    timeout_milliseconds := 10000
  )
  where exists (
    select 1 from arena_playback pb join arenas a on a.id = pb.arena_id
    where a.state = ''active''
  );
  ');
