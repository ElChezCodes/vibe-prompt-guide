import { supabase } from '@/integrations/supabase/client';
import { callSpotifyHost } from '@/integrations/supabase/spotify';

// Manual "like" (roadmap step 8): one of the user's own-affinity signals,
// never an auto-queue rule. Goes through spotify-host "like"
// (supabase/sql/like_vote_spotify_2026-10-27.sql): toggle_song_like counts as
// activity, votes for the song if the liker has no active vote (normal phase
// only), and the like is mirrored in the liker's own Spotify Liked Songs.

export async function getMySongLikes(arenaId: string): Promise<Set<string>> {
  const { data, error } = await supabase.rpc('get_my_song_likes', { p_arena_id: arenaId });
  if (error) {
    console.error('Failed to load likes:', error.message);
    return new Set();
  }
  return new Set((data ?? []) as string[]);
}

export type LikeSpotifyResult =
  | 'not_connected'
  | 'needs_reconnect'
  | 'saved'
  | 'already_saved'
  | 'removed'
  | 'kept'
  | 'error';

export interface LikeOutcome {
  liked: boolean;
  // The like cast the caller's vote for this song
  voted: boolean;
  spotify: LikeSpotifyResult;
}

export async function toggleSongLike(arenaId: string, songId: string): Promise<LikeOutcome> {
  return callSpotifyHost<LikeOutcome>({ action: 'like', arena_id: arenaId, song_id: songId });
}
