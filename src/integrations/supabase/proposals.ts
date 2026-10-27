import { supabase } from '@/integrations/supabase/client';
import { proposeSpotifyTrack, searchSpotifyTracks, SpotifyTrack } from '@/integrations/supabase/spotify';

// Active proposals (tier 1). Shared by the Battle Room modal and the Proponer
// screen so both read/write the same backend state.

export interface MyProposal {
  queue_id: string;
  song_id: string;
  title: string;
  artist: string;
  queue_type: 'waiting' | 'active';
  created_at: string;
}

export type ProposeResult = 'proposed' | 'already_queued';

// Spotify search with the arena host's token (no guest Spotify), see
// searchSpotifyTracks; the proposal itself goes through spotify-host so the
// track's metadata comes from Spotify, and the queues insert still runs as
// the caller (RLS, proposed_by stamp, presence).
export async function searchSongs(arenaId: string, query: string): Promise<SpotifyTrack[]> {
  return searchSpotifyTracks(query, arenaId);
}

export async function proposeSong(arenaId: string, spotifyTrackId: string): Promise<ProposeResult> {
  return proposeSpotifyTrack(arenaId, spotifyTrackId);
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
