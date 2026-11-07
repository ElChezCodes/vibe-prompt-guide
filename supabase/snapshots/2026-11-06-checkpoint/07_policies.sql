create policy arena_select_authenticated on public.arenas as PERMISSIVE for SELECT to public
  using (((auth.uid() IS NOT NULL) AND (state <> 'expired'::text)));

create policy host_select_arena on public.arenas as PERMISSIVE for SELECT to public
  using ((host_id = auth.uid()));

create policy battle_presence_snapshots_select on public.battle_presence_snapshots as PERMISSIVE for SELECT to authenticated
  using (((identity_anchor_id = auth.uid()) OR (arena_id IN ( SELECT arenas.id
   FROM arenas
  WHERE (arenas.host_id = auth.uid())))));

create policy battles_select_authenticated on public.battles as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy participants_can_read_active_battle on public.battles as PERMISSIVE for SELECT to public
  using (((state = 'active'::text) AND (arena_id IN ( SELECT p.arena_id
   FROM participants p
  WHERE (p.identity_anchor_id = auth.uid())))));

create policy participants_can_read_battles on public.battles as PERMISSIVE for SELECT to public
  using ((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.arena_id = battles.arena_id) AND (p.identity_anchor_id = auth.uid())))));

create policy participant_can_insert_self on public.participants as PERMISSIVE for INSERT to public
  with check ((identity_anchor_id = auth.uid()));

create policy participant_can_update_self on public.participants as PERMISSIVE for UPDATE to public
  using ((identity_anchor_id = auth.uid()));

create policy participant_can_view_arena_participants on public.participants as PERMISSIVE for SELECT to public
  using (((arena_id IN ( SELECT arenas.id
   FROM arenas
  WHERE (arenas.host_id = auth.uid()))) OR (identity_anchor_id = auth.uid())));

create policy participant_insert_self on public.participants as PERMISSIVE for INSERT to public
  with check ((identity_anchor_id = auth.uid()));

create policy participant_select on public.participants as PERMISSIVE for SELECT to public
  using (((identity_anchor_id = auth.uid()) OR (arena_id IN ( SELECT arenas.id
   FROM arenas
  WHERE (arenas.host_id = auth.uid())))));

create policy participants_is_host_matches_arena on public.participants as RESTRICTIVE for INSERT to public
  with check (((is_host = false) OR (EXISTS ( SELECT 1
   FROM arenas a
  WHERE ((a.id = participants.arena_id) AND (a.host_id = auth.uid()))))));

create policy participants_require_open_arena on public.participants as RESTRICTIVE for INSERT to public
  with check ((EXISTS ( SELECT 1
   FROM arenas a
  WHERE ((a.id = participants.arena_id) AND (a.state = ANY (ARRAY['waiting'::text, 'active'::text]))))));

create policy participants_update_is_host_matches_arena on public.participants as RESTRICTIVE for UPDATE to public
  using (true)
  with check (((is_host = false) OR (EXISTS ( SELECT 1
   FROM arenas a
  WHERE ((a.id = participants.arena_id) AND (a.host_id = auth.uid()))))));

create policy queues_insert_proposal on public.queues as PERMISSIVE for INSERT to public
  with check ((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.arena_id = queues.arena_id) AND (p.identity_anchor_id = auth.uid())))));

create policy queues_require_open_arena on public.queues as RESTRICTIVE for INSERT to public
  with check ((EXISTS ( SELECT 1
   FROM arenas a
  WHERE ((a.id = queues.arena_id) AND (a.state = ANY (ARRAY['waiting'::text, 'active'::text]))))));

create policy queues_select_arena on public.queues as PERMISSIVE for SELECT to public
  using ((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.arena_id = queues.arena_id) AND (p.identity_anchor_id = auth.uid())))));

create policy song_likes_select_arena on public.song_likes as PERMISSIVE for SELECT to public
  using ((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.arena_id = song_likes.arena_id) AND (p.identity_anchor_id = auth.uid())))));

create policy votes_insert_own_participant on public.votes as RESTRICTIVE for INSERT to public
  with check ((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.id = votes.participant_id) AND (p.identity_anchor_id = auth.uid()) AND (p.arena_id = votes.arena_id)))));

create policy votes_insert_regular_active on public.votes as PERMISSIVE for INSERT to public
  with check (((vote_type = 'regular'::text) AND (status = 'active'::text) AND (EXISTS ( SELECT 1
   FROM battles b
  WHERE ((b.id = votes.battle_id) AND (b.lockin_at IS NULL))))));

create policy votes_insert_sudden_death on public.votes as PERMISSIVE for INSERT to public
  with check (((vote_type = 'sudden_death'::text) AND (status = 'active'::text) AND (EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.id = votes.participant_id) AND (p.identity_anchor_id = auth.uid())))) AND (EXISTS ( SELECT 1
   FROM battles b
  WHERE ((b.id = votes.battle_id) AND (b.sudden_death_active = true))))));

create policy votes_require_active_arena on public.votes as RESTRICTIVE for INSERT to public
  with check ((EXISTS ( SELECT 1
   FROM (battles b
     JOIN arenas a ON ((a.id = b.arena_id)))
  WHERE ((b.id = votes.battle_id) AND (a.state = 'active'::text) AND (a.paused_at IS NULL)))));

create policy votes_sd_immutable on public.votes as RESTRICTIVE for UPDATE to public
  using ((vote_type <> 'sudden_death'::text))
  with check (true);

create policy votes_select_authenticated on public.votes as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy votes_update_before_lockin on public.votes as PERMISSIVE for UPDATE to public
  using (((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.id = votes.participant_id) AND (p.identity_anchor_id = auth.uid())))) AND (EXISTS ( SELECT 1
   FROM battles b
  WHERE ((b.id = votes.battle_id) AND (b.lockin_at IS NULL))))))
  with check (((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.id = votes.participant_id) AND (p.identity_anchor_id = auth.uid())))) AND (status = ANY (ARRAY['active'::text, 'cancelled'::text]))));

create policy votes_update_matches_phase on public.votes as RESTRICTIVE for UPDATE to public
  with check ((EXISTS ( SELECT 1
   FROM battles b
  WHERE ((b.id = votes.battle_id) AND (((votes.vote_type = 'regular'::text) AND (b.lockin_at IS NULL)) OR ((votes.vote_type = 'sudden_death'::text) AND (b.sudden_death_active = true)))))));

create policy votes_update_require_active_arena on public.votes as RESTRICTIVE for UPDATE to public
  using ((EXISTS ( SELECT 1
   FROM (battles b
     JOIN arenas a ON ((a.id = b.arena_id)))
  WHERE ((b.id = votes.battle_id) AND (a.state = 'active'::text) AND (a.paused_at IS NULL)))))
  with check ((EXISTS ( SELECT 1
   FROM (battles b
     JOIN arenas a ON ((a.id = b.arena_id)))
  WHERE ((b.id = votes.battle_id) AND (a.state = 'active'::text) AND (a.paused_at IS NULL)))));

create policy votes_upgrade_to_sudden_death on public.votes as PERMISSIVE for UPDATE to public
  using (((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.id = votes.participant_id) AND (p.identity_anchor_id = auth.uid())))) AND (vote_type = 'regular'::text)))
  with check (((EXISTS ( SELECT 1
   FROM participants p
  WHERE ((p.id = votes.participant_id) AND (p.identity_anchor_id = auth.uid())))) AND (vote_type = 'sudden_death'::text) AND (EXISTS ( SELECT 1
   FROM battles
  WHERE ((battles.id = votes.battle_id) AND (battles.sudden_death_active = true))))));
