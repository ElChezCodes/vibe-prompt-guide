-- ===========================================================================
-- Step 19 technical cleanup (user decision 2026-10-28): drop the vestigial
-- identity_anchors table. The identity anchor is the Supabase auth user id
-- (participants.identity_anchor_id = auth.uid()); nothing referenced this
-- table (no FKs, functions, views or triggers, checked 2026-10-29) and its
-- RLS only allowed the anon role, which anonymous sign-ins never use.
-- ===========================================================================

drop table if exists public.identity_anchors;
