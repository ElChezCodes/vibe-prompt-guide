import { supabase } from '@/integrations/supabase/client';

/**
 * The identity anchor IS the Supabase auth user id (auth.uid()): that's what
 * participants.identity_anchor_id, votes (fill_vote_fields) and RLS all use.
 *
 * This used to insert a random row into `identity_anchors` and cache it in
 * localStorage, but that id was never read anywhere, and the table's RLS only
 * allows the `anon` role -- anonymous sign-ins are `authenticated` -- so every
 * new browser failed here with "Failed to join arena".
 */
export async function getOrCreateIdentityAnchor(): Promise<string> {
  const { data: { session } } = await supabase.auth.getSession();

  if (!session?.user) {
    throw new Error('No authenticated session');
  }

  return session.user.id;
}
