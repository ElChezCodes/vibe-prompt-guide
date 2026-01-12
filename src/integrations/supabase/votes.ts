import { supabase } from "./client";

export type VoteType = 'regular' | 'sudden_death';

export interface Vote {
  id: string;
  battle_id: string;
  participant_id: string;
  song_id: string;
  status: 'active' | 'inactive';
  vote_type: VoteType;
  created_at: string;
  updated_at: string;
}

export type VoteAction = 'created' | 'toggled_off' | 'switched' | 'toggled_on' | 'locked' | 'error' | 'frozen';

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

function isRlsError(error: { code?: string; message?: string }): boolean {
  // RLS violations typically return code 42501 or contain specific messages
  return error.code === '42501' || 
         error.message?.includes('row-level security') ||
         error.message?.includes('violates row-level security policy');
}

export async function applyVoteIntent(
  battleId: string,
  participantId: string,
  songId: string,
  currentVote: Vote | null,
  arenaId: string,
  identityAnchorId: string,
  isLockedIn: boolean = false
): Promise<{ vote: Vote | null; action: VoteAction }> {
  // If locked in, reject all regular vote attempts
  if (isLockedIn) {
    return { vote: null, action: 'frozen' };
  }

  // No existing vote - INSERT new active vote with vote_type = 'regular'
  if (!currentVote) {
    const { data, error } = await supabase
      .from('votes')
      .insert({
        battle_id: battleId,
        participant_id: participantId,
        song_id: songId,
        status: 'active',
        vote_type: 'regular',
        arena_id: arenaId,
        identity_anchor_id: identityAnchorId
      })
      .select()
      .single();

    if (error) {
      console.error('Failed to insert vote:', error);
      if (isRlsError(error)) {
        return { vote: null, action: 'locked' };
      }
      return { vote: null, action: 'error' };
    }

    return { vote: data, action: 'created' };
  }

  // Sudden death votes cannot be modified
  if (currentVote.vote_type === 'sudden_death') {
    return { vote: currentVote, action: 'locked' };
  }

  // Existing regular vote - determine action
  const isSameSong = currentVote.song_id === songId;

  if (isSameSong) {
    // Toggle: active -> inactive, or inactive -> active
    const newStatus = currentVote.status === 'active' ? 'inactive' : 'active';
    const { data, error } = await supabase
      .from('votes')
      .update({ status: newStatus })
      .eq('id', currentVote.id)
      .eq('battle_id', battleId)
      .eq('participant_id', participantId)
      .select()
      .single();

    if (error) {
      console.error('Failed to toggle vote:', error);
      if (isRlsError(error)) {
        return { vote: null, action: 'locked' };
      }
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
        status: 'active'
      })
      .eq('id', currentVote.id)
      .eq('battle_id', battleId)
      .eq('participant_id', participantId)
      .select()
      .single();

    if (error) {
      console.error('Failed to switch vote:', error);
      if (isRlsError(error)) {
        return { vote: null, action: 'locked' };
      }
      return { vote: null, action: 'error' };
    }

    return { vote: data, action: 'switched' };
  }
}

export async function getActiveVoteCounts(
  battleId: string,
  voteType?: VoteType
): Promise<{ songACount: number; songBCount: number; songAId: string | null; songBId: string | null } | null> {
  // First get the battle to know song IDs
  const { data: battle, error: battleError } = await supabase
    .from('battles')
    .select('song_a_id, song_b_id')
    .eq('id', battleId)
    .single();

  if (battleError || !battle) {
    console.error('Failed to fetch battle for vote count:', battleError);
    return null;
  }

  // Count active votes for song A
  let songAQuery = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', battle.song_a_id)
    .eq('status', 'active');

  if (voteType) {
    songAQuery = songAQuery.eq('vote_type', voteType);
  }

  const { count: songACount, error: countAError } = await songAQuery;

  if (countAError) {
    console.error('Failed to count song A votes:', countAError);
    return null;
  }

  // Count active votes for song B
  let songBQuery = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', battle.song_b_id)
    .eq('status', 'active');

  if (voteType) {
    songBQuery = songBQuery.eq('vote_type', voteType);
  }

  const { count: songBCount, error: countBError } = await songBQuery;

  if (countBError) {
    console.error('Failed to count song B votes:', countBError);
    return null;
  }

  return {
    songACount: songACount ?? 0,
    songBCount: songBCount ?? 0,
    songAId: battle.song_a_id,
    songBId: battle.song_b_id
  };
}
