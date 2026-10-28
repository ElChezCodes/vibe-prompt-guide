-- Roadmap step 7b: optional Music Fighter accounts (user decisions 2026-10-27).
--
-- Entering arenas stays anonymous. Anyone may turn their anonymous session
-- into an account with an email + 6-digit code:
--   * new email      -> supabase.auth.updateUser({ email }) + verifyOtp
--                       (type email_change): same auth.uid(), nothing to move;
--   * existing email -> the person already has an account (another device).
--                       Before switching they get a merge ticket as the
--                       anonymous user; after signing in (signInWithOtp +
--                       verifyOtp type email) the spotify-host Edge Function
--                       action merge_anonymous claims it and FUSES the
--                       anonymous user's data into the account (user decision:
--                       merge, not discard), re-encrypting a Spotify
--                       connection if needed (tokens are bound to the user id),
--                       then deletes the anonymous auth user.
-- Privacy: consent to the privacy policy is recorded per user and version;
-- "Delete account" (spotify-host delete_account) ends the arenas they host,
-- deletes their Spotify data and the auth user. Arena history rows
-- (participants/votes/proposals) keep only the now-unlinkable user id.

-- ---------------------------------------------------------------------------
-- Merge tickets: proof, created while still anonymous, that the account that
-- signs in next may absorb this anonymous user. Single use, 10 min.
-- ---------------------------------------------------------------------------
create table if not exists public.account_merge_tickets (
  ticket text primary key,
  anon_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes'
);
alter table public.account_merge_tickets enable row level security;
-- No policies: only create_merge_ticket (definer) and the Edge Function touch it
revoke all on public.account_merge_tickets from anon, authenticated;

create or replace function public.create_merge_ticket()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_ticket text;
begin
  if v_uid is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
    raise exception 'only an anonymous session can be merged into an account';
  end if;
  delete from account_merge_tickets where anon_user_id = v_uid or expires_at < now();
  v_ticket := encode(gen_random_bytes(32), 'hex');
  insert into account_merge_tickets (ticket, anon_user_id) values (v_ticket, v_uid);
  return v_ticket;
end;
$$;
revoke all on function public.create_merge_ticket() from public, anon;
grant execute on function public.create_merge_ticket() to authenticated;

-- ---------------------------------------------------------------------------
-- Privacy consent (policy version shown on /privacy)
-- ---------------------------------------------------------------------------
create table if not exists public.privacy_consents (
  user_id uuid primary key references auth.users(id) on delete cascade,
  policy_version text not null,
  accepted_at timestamptz not null default now()
);
alter table public.privacy_consents enable row level security;
revoke all on public.privacy_consents from anon, authenticated;

create or replace function public.record_privacy_consent(p_version text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'sign in first';
  end if;
  insert into privacy_consents (user_id, policy_version)
  values (auth.uid(), left(p_version, 20))
  on conflict (user_id) do update set policy_version = excluded.policy_version, accepted_at = now();
end;
$$;
revoke all on function public.record_privacy_consent(text) from public, anon;
grant execute on function public.record_privacy_consent(text) to authenticated;

-- ---------------------------------------------------------------------------
-- merge_anonymous_user: service-only, called by spotify-host after it has
-- validated the ticket and handled streaming_accounts (encrypted tokens can't
-- be moved in SQL). Runs without auth.uid(), so the presence triggers don't
-- count the merge as activity.
-- Same arena on both sides: the account's participant row is kept, the more
-- recent of the two votes per battle survives (the vote unique index allows
-- one row per participant and battle), presence times are combined.
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
  delete from spotify_oauth_states where user_id = p_from;
  delete from account_merge_tickets where anon_user_id = p_from;

  return jsonb_build_object('arenas_moved', v_moved, 'arenas_fused', v_fused);
end;
$$;
revoke all on function public.merge_anonymous_user(uuid, uuid) from public, anon, authenticated;
grant execute on function public.merge_anonymous_user(uuid, uuid) to service_role;
