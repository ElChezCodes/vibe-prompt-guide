import { supabase } from '@/integrations/supabase/client';

export interface Participant {
  id: string;
  arena_id: string;
  identity_anchor_id: string;
  is_host: boolean;
  left_at: string | null;
  created_at: string;
}

// Entering the arena (Battle Room, host Lobby) is the (re-)join and counts as
// activity: enter_arena inserts or fetches the row, clears a previous "Leave
// arena" and stamps last_active_at server-side. identity/is_host are decided
// by the backend from auth.uid(); the args are kept for existing callers.
export async function ensureParticipant(
  arena_id: string,
  _identity_anchor_id: string,
  _is_host: boolean
): Promise<Participant> {
  const { data, error } = await supabase
    .rpc('enter_arena', { p_arena_id: arena_id })
    .single();

  if (error) {
    console.error('Failed to enter arena:', error.message, error);
    throw error;
  }

  return data as Participant;
}

// The caller's own participant row, without joining (null if not a member)
export async function getOwnParticipant(arena_id: string): Promise<Participant | null> {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session?.user) return null;

  const { data, error } = await supabase
    .from('participants')
    .select('*')
    .eq('arena_id', arena_id)
    .eq('identity_anchor_id', session.user.id)
    .maybeSingle();

  if (error) {
    console.error('Failed to fetch participant:', error.message, error);
    throw error;
  }

  return (data as Participant) ?? null;
}
