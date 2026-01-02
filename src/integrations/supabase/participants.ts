import { supabase } from '@/integrations/supabase/client';

export interface Participant {
  id: string;
  arena_id: string;
  identity_anchor_id: string;
  is_host: boolean;
  created_at: string;
}

export async function createParticipant(
  arena_id: string,
  identity_anchor_id: string
): Promise<Participant> {
  const { data, error } = await supabase
    .from('participants')
    .insert({
      arena_id,
      identity_anchor_id,
      is_host: false,
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create participant:', error.message, error);
    throw error;
  }

  return data as Participant;
}
