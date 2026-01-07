import { supabase } from "./client";

export interface Vote {
  id: string;
  battle_id: string;
  participant_id: string;
  song_id: string;
  status: 'active' | 'inactive';
  created_at: string;
  updated_at: string;
}

export async function getParticipantVote(
  battleId: string,
  participantId: string
): Promise<Vote | null> {
  const { data, error } = await supabase
    .from('votes')
    .select('*')
    .eq('battle_id', battleId)
    .eq('participant_id', participantId)
    .maybeSingle();

  if (error) {
    console.error('Failed to fetch vote:', error);
    return null;
  }

  return data;
}

export async function upsertVote(
  battleId: string,
  participantId: string,
  songId: string,
  currentVote: Vote | null
): Promise<{ vote: Vote | null; action: 'created' | 'toggled_off' | 'switched' | 'toggled_on' | 'error' }> {
  // No existing vote - INSERT new active vote
  if (!currentVote) {
    const { data, error } = await supabase
      .from('votes')
      .insert({
        battle_id: battleId,
        participant_id: participantId,
        song_id: songId,
        status: 'active'
      })
      .select()
      .single();

    if (error) {
      console.error('Failed to insert vote:', error);
      return { vote: null, action: 'error' };
    }

    return { vote: data, action: 'created' };
  }

  // Existing vote - determine action
  const isSameSong = currentVote.song_id === songId;

  if (isSameSong) {
    // Toggle: active -> inactive, or inactive -> active
    const newStatus = currentVote.status === 'active' ? 'inactive' : 'active';
    const { data, error } = await supabase
      .from('votes')
      .update({ 
        status: newStatus,
        updated_at: new Date().toISOString()
      })
      .eq('id', currentVote.id)
      .select()
      .single();

    if (error) {
      console.error('Failed to toggle vote:', error);
      return { vote: null, action: 'error' };
    }

    return { 
      vote: data, 
      action: newStatus === 'inactive' ? 'toggled_off' : 'toggled_on' 
    };
  } else {
    // Different song - switch vote and set active
    const { data, error } = await supabase
      .from('votes')
      .update({ 
        song_id: songId,
        status: 'active',
        updated_at: new Date().toISOString()
      })
      .eq('id', currentVote.id)
      .select()
      .single();

    if (error) {
      console.error('Failed to switch vote:', error);
      return { vote: null, action: 'error' };
    }

    return { vote: data, action: 'switched' };
  }
}
