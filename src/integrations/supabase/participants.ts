import { supabase } from '@/integrations/supabase/client';

export interface Participant {
  id: string;
  arena_id: string;
  identity_anchor_id: string;
  is_host: boolean;
  left_at: string | null;
  created_at: string;
}

export async function ensureParticipant(
  arena_id: string,
  identity_anchor_id: string,
  is_host: boolean
): Promise<Participant> {
  // Check if participant already exists (idempotent)
  const { data: existing } = await supabase
    .from('participants')
    .select('*')
    .eq('arena_id', arena_id)
    .eq('identity_anchor_id', identity_anchor_id)
    .maybeSingle();

  if (existing) {
    // Re-entering after "Salir de la arena" is the explicit re-join
    if (existing.left_at) {
      const { data: rejoined, error } = await supabase
        .from('participants')
        .update({ left_at: null })
        .eq('id', existing.id)
        .select()
        .single();

      if (error) {
        console.error('Failed to re-join arena:', error.message, error);
        throw error;
      }

      return rejoined as Participant;
    }

    return existing as Participant;
  }

  // Insert new participant
  const { data, error } = await supabase
    .from('participants')
    .insert({
      arena_id,
      identity_anchor_id,
      is_host,
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create participant:', error.message, error);
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
