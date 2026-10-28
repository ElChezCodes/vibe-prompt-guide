import { supabase } from '@/integrations/supabase/client';

// Manual "like" (roadmap step 8): one of the user's own-affinity signals,
// never an auto-queue rule. Writes only through toggle_song_like
// (supabase/sql/affinity_passive_vote_2026-10-27.sql), which also counts as
// activity in the arena.

export async function getMySongLikes(arenaId: string): Promise<Set<string>> {
  const { data, error } = await supabase.rpc('get_my_song_likes', { p_arena_id: arenaId });
  if (error) {
    console.error('Failed to load likes:', error.message);
    return new Set();
  }
  return new Set((data ?? []) as string[]);
}

// Returns whether the song is liked now
export async function toggleSongLike(arenaId: string, songId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('toggle_song_like', { p_arena_id: arenaId, p_song_id: songId });
  if (error) throw new Error(error.message);
  return !!data;
}
