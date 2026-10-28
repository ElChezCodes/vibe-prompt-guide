import { supabase } from '@/integrations/supabase/client';
import {
  CatalogAccount,
  ProposeOutcome,
  proposeSpotifyTrack,
  searchArenaTracks,
  SpotifyTrack,
} from '@/integrations/supabase/spotify';

// Active proposals (tier 1). Shared by the Battle Room modal and the Proponer
// screen so both read/write the same backend state.

// Queued: next (one of the next 10) | waiting (place in the waiting list,
// battles_left before the 20-battle purge). History in this arena:
// competing | won | lost | draw | cancelled | purged | withdrawn.
export type ProposalStatus =
  | 'next'
  | 'waiting'
  | 'competing'
  | 'won'
  | 'lost'
  | 'draw'
  | 'cancelled'
  | 'purged'
  | 'withdrawn';

export interface MyProposal {
  queue_id: string | null; // only while queued (withdraw)
  song_id: string;
  title: string;
  artist: string;
  artwork_url: string | null;
  status: ProposalStatus;
  place: number | null;
  battles_left: number | null;
  at: string;
}

// Spotify search with the member's own account or the host's (step 7, see
// searchArenaTracks); the proposal itself goes through spotify-host so the
// track's metadata comes from Spotify, and the queues insert still runs as
// the caller (RLS, proposed_by stamp, presence), whatever the song's source.
export async function searchSongs(
  arenaId: string,
  query: string,
  account: CatalogAccount,
): Promise<{ tracks: SpotifyTrack[]; account: CatalogAccount }> {
  return searchArenaTracks(arenaId, query, account);
}

export async function proposeSong(
  arenaId: string,
  spotifyTrackId: string,
  account: CatalogAccount = 'own',
): Promise<ProposeOutcome> {
  return proposeSpotifyTrack(arenaId, spotifyTrackId, account);
}

// The caller's queued proposals in battle order, then what happened to the
// ones that left the queue (step 12, get_my_proposals).
export async function getMyProposals(arenaId: string): Promise<MyProposal[]> {
  const { data, error } = await supabase.rpc('get_my_proposals', { p_arena_id: arenaId });

  if (error) {
    console.error('Failed to load proposals:', error.message, error);
    throw error;
  }

  return (data ?? []) as MyProposal[];
}

// Step 12b: fewer than this many human proposals queued -> "propose a song"
export const LOW_QUEUE_THRESHOLD = 4;

export interface ArenaQueueSummary {
  human_queued: number;
  waiting_for_songs: boolean; // active arena without an open battle: no pair yet
}

export async function getArenaQueueSummary(arenaId: string): Promise<ArenaQueueSummary | null> {
  const { data, error } = await supabase.rpc('get_arena_queue_summary', { p_arena_id: arenaId });

  if (error) {
    console.error('Failed to load queue summary:', error.message, error);
    throw error;
  }

  return ((data ?? [])[0] ?? null) as ArenaQueueSummary | null;
}

// Only the proposer, only while it is still queued
export async function withdrawProposal(queueId: string): Promise<void> {
  const { error } = await supabase.rpc('withdraw_proposal', { p_queue_id: queueId });

  if (error) {
    console.error('Failed to withdraw proposal:', error.message, error);
    throw error;
  }
}
