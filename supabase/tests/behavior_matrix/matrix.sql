\set QUIET on
set client_min_messages = notice;
-- reads: who sees what
do $$
declare u record; t text;
begin
  for u in select * from (values ('host','authenticated',':H:'),('member','authenticated',':M:'),('stranger','authenticated',':S:'),('nosession','anon',null)) v(n,r,i) loop
    foreach t in array array['arenas','battles','participants','queues','song_likes','battle_presence_snapshots','votes','songs','hosts','playlist_queue','pi_ledger','user_profiles','streaming_accounts','proposal_history','arena_playback','recordings','affinity_signals','matchmaking_log','arena_song_reserve'] loop
      call zt.t('read '||t||' as '||u.n, u.r, u.i, format('select count(*)::text from public.%I', t));
    end loop;
    call zt.t('live_state hash as '||u.n, u.r, u.i, $q$select md5(coalesce(string_agg(x::text,'|' order by x.battle_id),'')) from public.arena_live_state x where arena_id=':A:'$q$);
    call zt.t('live_state count all as '||u.n, u.r, u.i, 'select count(*)::text from public.arena_live_state');
    call zt.t('participant_presence as '||u.n, u.r, u.i, 'select count(*)::text from public.participant_presence');
  end loop;
end $$;
-- votes
call zt.t('vote regular member','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':P:',':M:','regular','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote regular for other participant','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':PY:',':Y:','regular','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote regular stranger','authenticated',':S:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':P:',':S:','regular','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote regular locked battle','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B2:',':S2A:',':P:',':M:','regular','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote sudden death member','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B2:',':S2A:',':P:',':M:','sudden_death','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote sudden death in non-sd battle','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':P:',':M:','sudden_death','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote passive by client','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':P:',':M:','passive','active') returning 1) select count(*)::text from i$q$);
call zt.t('vote while paused','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':P:',':M:','regular','active') returning 1) select count(*)::text from i$q$, $q$update arenas set paused_at=now() where id=':A:'$q$);
call zt.t('vote arena finished','authenticated',':M:',$q$with i as (insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) values (':A:',':B1:',':SA:',':P:',':M:','regular','active') returning 1) select count(*)::text from i$q$, $q$update arenas set state='finished' where id=':A:'$q$);
create or replace function zt.seedvote(b text, s text, ty text) returns void language plpgsql as $f$ begin
 set local session_replication_role = replica;
 insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status) select b2.arena_id,b2.id,s::uuid,(select v from zt.ids where k='P')::uuid,(select v from zt.ids where k='M')::uuid,ty,'active' from battles b2 where b2.id=b::uuid;
 set local session_replication_role = origin; end $f$;
call zt.t('switch vote','authenticated',':M:',$q$with u as (update votes set song_id=':SB:' where battle_id=':B1:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B1:',':SA:','regular')$q$);
call zt.t('cancel vote','authenticated',':M:',$q$with u as (update votes set status='cancelled' where battle_id=':B1:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B1:',':SA:','regular')$q$);
call zt.t('update someone elses vote','authenticated',':S:',$q$with u as (update votes set status='cancelled' where battle_id=':B1:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B1:',':SA:','regular')$q$);
call zt.t('upgrade regular to sd','authenticated',':M:',$q$with u as (update votes set vote_type='sudden_death' where battle_id=':B2:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B2:',':S2A:','regular')$q$);
call zt.t('change sd vote (immutable)','authenticated',':M:',$q$with u as (update votes set status='cancelled' where battle_id=':B2:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B2:',':S2A:','sudden_death')$q$);
call zt.t('update regular after lock-in','authenticated',':M:',$q$with u as (update votes set status='cancelled' where battle_id=':B2:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B2:',':S2A:','regular')$q$);
call zt.t('delete vote','authenticated',':M:',$q$with u as (delete from votes where battle_id=':B1:' and participant_id=':P:' returning 1) select count(*)::text from u$q$, $q$select zt.seedvote(':B1:',':SA:','regular')$q$);
-- participants
call zt.t('join self','authenticated',':S:',$q$with i as (insert into participants(arena_id,identity_anchor_id) values (':A:',':S:') returning 1) select count(*)::text from i$q$);
call zt.t('join as other','authenticated',':S:',$q$with i as (insert into participants(arena_id,identity_anchor_id) values (':A:',':Y:') returning 1) select count(*)::text from i$q$);
call zt.t('join claiming host','authenticated',':S:',$q$with i as (insert into participants(arena_id,identity_anchor_id,is_host) values (':A:',':S:',true) returning 1) select count(*)::text from i$q$);
call zt.t('join finished arena','authenticated',':S:',$q$with i as (insert into participants(arena_id,identity_anchor_id) values (':A:',':S:') returning 1) select count(*)::text from i$q$, $q$update arenas set state='finished' where id=':A:'$q$);
call zt.t('update own participant','authenticated',':M:',$q$with u as (update participants set display_name='x' where id=':P:' returning 1) select count(*)::text from u$q$);
call zt.t('claim host by update','authenticated',':M:',$q$with u as (update participants set is_host=true where id=':P:' returning 1) select count(*)::text from u$q$);
call zt.t('update other participant','authenticated',':M:',$q$with u as (update participants set display_name='x' where id=':PY:' returning 1) select count(*)::text from u$q$);
-- queues
call zt.t('propose member','authenticated',':M:',$q$with i as (insert into queues(arena_id,song_id) values (':A:',':NS:') returning 1) select count(*)::text from i$q$);
call zt.t('propose stranger','authenticated',':S:',$q$with i as (insert into queues(arena_id,song_id) values (':A:',':NS:') returning 1) select count(*)::text from i$q$);
call zt.t('propose song in battle','authenticated',':M:',$q$with i as (insert into queues(arena_id,song_id) values (':A:',':SA:') returning 1) select count(*)::text from i$q$);
call zt.t('propose finished arena','authenticated',':M:',$q$with i as (insert into queues(arena_id,song_id) values (':A:',':NS:') returning 1) select count(*)::text from i$q$, $q$update arenas set state='finished' where id=':A:'$q$);
call zt.t('delete queue','authenticated',':M:',$q$with u as (delete from queues where arena_id=':A:' returning 1) select count(*)::text from u$q$);
-- client must not write these
call zt.t('client insert battle','authenticated',':H:',$q$insert into battles(arena_id) values (':A:')$q$);
call zt.t('client update battle','authenticated',':H:',$q$update battles set winner_song_id=song_a_id where id=':B1:'$q$);
call zt.t('client update arena','authenticated',':H:',$q$update arenas set state='finished' where id=':A:'$q$);
call zt.t('client update song','authenticated',':H:',$q$update songs set title='x' where id=':SA:'$q$);
-- RPCs
do $$
declare u record; c text;
begin
  for u in select * from (values ('host','authenticated',':H:'),('member','authenticated',':M:'),('stranger','authenticated',':S:'),('nosession','anon',null)) v(n,r,i) loop
    foreach c in array array[
      'get_stage_view('':CODE:'')','get_arena_next_up('':A:'')','get_arena_playback('':A:'')','get_arena_presence('':A:'')','get_arena_queue_summary('':A:'')','get_arena_warmup('':A:'')','get_my_pi('':A:'')','get_my_proposals('':A:'')','get_my_song_likes('':A:'')','get_my_profile()','get_arena_pi_leaderboard('':A:'')','get_pi_leaderboard(''world'',''all'',null,10)','get_my_passive_vote('':B1:'')','get_current_arena()','get_my_past_arenas(5)','get_my_streaming_connection()','resolve_vote_token('':TOK:'',''a'')','battle_passive_tally('':B1:'')','can_read_warmup_audio(''x'')','track_available_at('':A:'',''x'')']
    loop
      call zt.t('rpc '||split_part(c,'(',1)||' as '||u.n, u.r, u.i, 'select count(*)::text from public.'||c);
    end loop;
    foreach c in array array['enter_arena('':A:'')','presence_heartbeat()','toggle_song_like('':A:'','':SA:'')','back_proposal('':A:'','':NS:'',''list'')','leave_arena('':A:'')','set_arena_control_mode('':A:'',''manual'')','end_arena('':A:'')','start_arena_battles('':A:'')','record_privacy_consent(''2026-10-28'')','update_my_profile(''Tester'',null)','create_merge_ticket()']
    loop
      call zt.t('rpcw '||split_part(c,'(',1)||' as '||u.n, u.r, u.i, 'select public.'||c||' is null');
    end loop;
  end loop;
end $$;
call zt.t('direct call trigger fn','authenticated',':M:','select public.touch_activity_on_vote()');
-- server jobs
call zt.t('job lock-in no votes','postgres',null,'select process_battle_lifecycle('':A:'') is null', 'update battles set state=''completed'', sudden_death_active=false, resolution_type=''cancelled'' where id='':B2:''; update battles set started_at=now()-interval ''59 minutes 45 seconds'' where id='':B1:''', 'select state||'':''||coalesce(resolution_type,''-'')||'':''||sudden_death_active::text from battles where id='':B1:''');
call zt.t('job lock-in one vote','postgres',null,'select process_battle_lifecycle('':A:'') is null', 'update battles set state=''completed'', sudden_death_active=false, resolution_type=''cancelled'' where id='':B2:''; update battles set started_at=now()-interval ''59 minutes 45 seconds'' where id='':B1:''; select zt.seedvote('':B1:'','':SA:'',''regular'')', 'select state||'':''||coalesce(resolution_type,''-'')||'':''||sudden_death_active::text from battles where id='':B1:''');
call zt.t('job sd close','postgres',null,'select process_battle_lifecycle('':A:'') is null', 'update battles set started_at=now()-interval ''2 hours'', sudden_death_started_at=now()-interval ''1 minute'' where id='':B2:''', 'select state||'':''||coalesce(resolution_type,''-'')||'':''||sudden_death_active::text from battles where id='':B2:''');
call zt.t('job complete and next','postgres',null,'select process_battle_lifecycle('':A:'') is null', 'update battles set state=''completed'', sudden_death_active=false, resolution_type=''cancelled'' where id='':B2:''; update battles set state=''closing'', lockin_at=now(), resolution_type=''normal'', winner_song_id=song_a_id, started_at=now()-interval ''2 hours'' where id='':B1:''', 'select (select state from battles where id='':B1:'')||'':''||(select count(*) from battles where arena_id='':A:'' and state<>''completed'')');
call zt.t('job create next','postgres',null,'select create_next_battle('':A:'') is null', 'update battles set state=''completed'', sudden_death_active=false, resolution_type=''cancelled'' where id='':B2:''; update battles set state=''completed'', resolution_type=''cancelled'' where id='':B1:''', 'select count(*)::text from battles where arena_id='':A:'' and state<>''completed''');
call zt.t('job expire','postgres',null,$q$select expire_stale_arenas() is null$q$);
call zt.t('job purge','postgres',null,$q$select purge_old_arena_votes() is null$q$);
call zt.t('job prepare generate code','postgres',null,$q$select length(generate_arena_code())::text$q$);
call zt.t('job normalize isrc','postgres',null,$q$select normalize_isrc('us-abc-12-34567')$q$);
call zt.t('job presence_state count','postgres',null,$q$select count(*)::text from participant_presence$q$);
call zt.t('job calculate totals','postgres',null,$q$select count(*)::text from calculate_lockin_vote_totals(':B2:')$q$);
