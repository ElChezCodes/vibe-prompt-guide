import { supabase } from '@/integrations/supabase/client';

// Active proposals (tier 1). Shared by the Battle Room modal and the Proponer
// screen so both read/write the same backend state.

export interface SongResult {
  id: string;
  title: string;
  artist: string;
}

export interface MyProposal {
  queue_id: string;
  song_id: string;
  title: string;
  artist: string;
  queue_type: 'waiting' | 'active';
  created_at: string;
}

export type ProposeResult = 'proposed' | 'already_queued';

// Server-side: this arena's songs + the curated library (songs table has no
// client SELECT policy by design)
export async function searchSongs(arenaId: string, query: string): Promise<SongResult[]> {
  const { data, error } = await supabase.rpc('search_songs', {
    p_arena_id: arenaId,
    p_query: query,
  });

  if (error) {
    console.error('Song search failed:', error.message, error);
    throw error;
  }

  return (data ?? []) as SongResult[];
}

// proposed_by is stamped from auth.uid() by a trigger, never sent by the client
export async function proposeSong(arenaId: string, songId: string): Promise<ProposeResult> {
  const { error } = await supabase.from('queues').insert({
    arena_id: arenaId,
    song_id: songId,
    queue_type: 'waiting',
    position: 0,
    priority: 1,
  });

  if (error) {
    // Unique violation (queues_arena_song_unique): someone already queued it
    if (error.code === '23505') return 'already_queued';
    console.error('Proposal insert failed:', error.message, error);
    throw error;
  }

  return 'proposed';
}

// Still-queued proposals only: pull_next_battle_songs deletes a queue row
// when its song enters a battle.
export async function getMyProposals(arenaId: string): Promise<MyProposal[]> {
  const { data, error } = await supabase.rpc('get_my_proposals', { p_arena_id: arenaId });

  if (error) {
    console.error('Failed to load proposals:', error.message, error);
    throw error;
  }

  return (data ?? []) as MyProposal[];
}
