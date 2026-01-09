import { supabase } from '@/integrations/supabase/client';

export interface Participant {
  id: string;
  arena_id: string;
  identity_anchor_id: string;
  is_host: boolean;
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
