import { supabase } from '@/integrations/supabase/client';
import { normalizeArenaCode } from '@/integrations/supabase/arenas';
import { NextUpSong } from '@/integrations/supabase/proposals';

// Who proposed a song of the battle on screen. proposer null = a system song
// (reserve, lent Liked Songs, a member's profile, system revancha): anonymous.
export interface StageSongCredit {
  proposer: string | null;
  pi: number;
  backers: number;
}

export interface StageViewData {
  arena: {
    id: string;
    name: string;
    code: string;
    state: 'waiting' | 'active' | 'finished';
    mood: string | null;
    started_at: string | null;
    paused_at: string | null;
    pause_reason: string | null;
  };
  warmup: {
    title: string;
    artist: string;
    artwork_url: string | null;
    spotify_track_id: string;
    duration_ms: number | null;
  } | null;
  people: { joined: number; active: number; passive: number };
  waiting_for_songs: boolean;
  playback: {
    is_playing: boolean;
    player_context: string | null;
    now_playing_kind: 'warmup' | 'winner' | null;
    now_playing_title: string | null;
    now_playing_artist: string | null;
    now_playing_artwork_url: string | null;
    now_playing_spotify_track_id: string | null;
    next_title: string | null;
    next_artist: string | null;
    unplayable_title: string | null;
  } | null;
  battle: { battle_id: string; a: StageSongCredit | null; b: StageSongCredit | null } | null;
  next_up: NextUpSong[];
  // Top 3 during the arena, everyone once it finished; next_up = the first 5
  leaderboard: { place: number; display_name: string; pi: number; is_host: boolean }[];
}

/**
 * Step 19a: everything the shared screen shows around the live battle, from
 * the database only (no Spotify calls). Anyone with the code; null = no such
 * arena (or expired).
 */
export async function getStageView(code: string): Promise<StageViewData | null> {
  const { data, error } = await supabase.rpc('get_stage_view', { p_code: normalizeArenaCode(code) });

  if (error) {
    console.error('Failed to load stage view:', error.message, error);
    throw error;
  }

  return (data ?? null) as StageViewData | null;
}
