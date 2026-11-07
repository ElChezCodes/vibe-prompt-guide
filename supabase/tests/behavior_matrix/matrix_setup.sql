-- Throwaway copy only.
set session_replication_role = replica;
create schema if not exists zt;
create table if not exists zt.ids(k text primary key, v text);
truncate zt.ids;
do $$
declare a uuid; h uuid; m uuid; p uuid; y uuid; py uuid; s uuid; b1 uuid; b2 uuid; b0 uuid; ns uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; ss uuid; lk uuid; q uuid;
begin
  select id, host_id into a, h from arenas where arena_code='F3C0E7';
  select identity_anchor_id, id into m, p from participants where arena_id=a and not is_host order by id limit 1;
  select identity_anchor_id, id into y, py from participants where arena_id=a and not is_host order by id offset 1 limit 1;
  select u.id into s from auth.users u where not exists (select 1 from participants x where x.arena_id=a and x.identity_anchor_id=u.id) order by u.id limit 1;
  select id into b1 from battles where arena_id=a order by created_at desc limit 1;
  select id into b2 from battles where arena_id=a order by created_at desc offset 1 limit 1;
  select id into b0 from battles where arena_id=a order by created_at desc offset 2 limit 1;
  update arenas set state='active', paused_at=null, ended_at=null, votes_purged_at=null where id=a;
  update participants set left_at=null, last_seen_at=now(), last_active_at=now() where arena_id=a;
  update battles set state='active', lockin_at=null, sudden_death_active=false, sudden_death_started_at=null, resolution_type=null, winner_song_id=null, started_at=now(), duration_ms=3600000, vote_token='aaaaaaaaaaaa' where id=b1;
  update battles set state='closing', lockin_at=now(), sudden_death_active=true, sudden_death_started_at=now(), resolution_type=null, winner_song_id=null, started_at=now()-interval '1 minute', duration_ms=3600000 where id=b2;
  delete from votes where battle_id in (b1,b2) and participant_id in (p,py);
  insert into votes(arena_id,battle_id,song_id,participant_id,identity_anchor_id,vote_type,status,weight) select a,b0,song_a_id,py,y,'regular','active',1 from battles where id=b0 on conflict do nothing;
  select id into ss from songs where arena_id=a and role<>'warmup' order by id limit 1;
  if not exists (select 1 from songs where id=ns) then
    insert into songs select (jsonb_populate_record(x, jsonb_build_object('id',ns,'spotify_track_id','zt-track-1','isrc',null))).* from songs x where id=ss;
  end if;
  insert into zt.ids values ('A',a::text),('H',h::text),('M',m::text),('P',p::text),('Y',y::text),('PY',py::text),('S',s::text),('B1',b1::text),('B2',b2::text),('B0',b0::text),('NS',ns::text);
  insert into zt.ids select 'SA',song_a_id::text from battles where id=b1;
  insert into zt.ids select 'SB',song_b_id::text from battles where id=b1;
  insert into zt.ids select 'S2A',song_a_id::text from battles where id=b2;
  insert into zt.ids select 'TOK',vote_token from battles where id=b1;
  insert into zt.ids values ('CODE','F3C0E7');
end $$;
set session_replication_role = origin;
create or replace procedure zt.t(label text, r text, uid text, q text, pre text default null, post text default null)
language plpgsql as $p$
declare res text; rw text; kv record; st text; msg text;
  sub text;
begin
  for kv in select i.k as kk, coalesce(i.v,'') as vv from zt.ids i order by length(i.k) desc loop
    q := replace(q, ':'||kv.kk||':', kv.vv); pre := replace(pre, ':'||kv.kk||':', kv.vv); post := replace(post, ':'||kv.kk||':', kv.vv); uid := replace(uid, ':'||kv.kk||':', kv.vv);
  end loop;
  begin
    if pre is not null then execute pre; end if;
    if uid is not null then perform set_config('request.jwt.claims', json_build_object('sub',uid,'role','authenticated')::text, true); else perform set_config('request.jwt.claims', '', true); end if;
    execute format('set local role %I', r);
    execute q into res;
    if post is not null then execute post into rw; res := coalesce(res,'null')||' / '||coalesce(rw,'null'); end if;
    raise exception 'zt-ok' using errcode='ZZ001', detail=coalesce(res,'null');
  exception
    when sqlstate 'ZZ001' then
      get stacked diagnostics msg = pg_exception_detail;
      raise notice 'RES|%|OK|%', label, msg;
    when others then
      get stacked diagnostics st = returned_sqlstate, msg = message_text;
      raise notice 'RES|%|ERR|%|%', label, st, left(regexp_replace(msg,'[0-9a-f]{8}-[0-9a-f-]{27}','<id>','g'),80);
  end;
end $p$;
grant usage on schema zt to anon, authenticated, postgres;
