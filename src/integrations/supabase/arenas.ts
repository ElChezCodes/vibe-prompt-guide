import { supabase } from '@/integrations/supabase/client';

// Backend-authoritative (see supabase/sql/arena_state_model_2026-10-26.sql).
// Transitions happen only via RPCs: create_arena -> waiting,
// start_arena_battles -> active, end_arena -> finished, cron -> expired.
export type ArenaState = 'waiting' | 'active' | 'finished' | 'expired';

// Must match the arenas_mood_check constraint (Block 2 §2 suggested values,
// expanded). Groups are display-only.
export const ARENA_MOODS = [
  // Vibe
  { value: 'chill', label: 'Chill', emoji: '🌙', group: 'Vibe' },
  { value: 'party', label: 'Party', emoji: '🎉', group: 'Vibe' },
  { value: 'energetic', label: 'Energetic', emoji: '🔥', group: 'Vibe' },
  { value: 'romantic', label: 'Romantic', emoji: '💘', group: 'Vibe' },
  { value: 'dance', label: 'Dance', emoji: '🕺', group: 'Vibe' },
  { value: 'workout', label: 'Workout', emoji: '💪', group: 'Vibe' },
  { value: 'focus', label: 'Focus', emoji: '🎧', group: 'Vibe' },
  { value: 'sunset', label: 'Sunset', emoji: '🌅', group: 'Vibe' },
  { value: 'brunch', label: 'Brunch', emoji: '🥂', group: 'Vibe' },
  { value: 'late-night', label: 'Late Night', emoji: '🌃', group: 'Vibe' },
  { value: 'after-party', label: 'After Party', emoji: '🪩', group: 'Vibe' },
  { value: 'lounge', label: 'Lounge', emoji: '🍸', group: 'Vibe' },
  { value: 'karaoke', label: 'Karaoke', emoji: '🎙️', group: 'Vibe' },
  { value: 'festival', label: 'Festival', emoji: '🎪', group: 'Vibe' },
  { value: 'tropical', label: 'Tropical', emoji: '🌴', group: 'Vibe' },
  { value: 'feel-good', label: 'Feel Good', emoji: '😄', group: 'Vibe' },
  { value: 'melancholic', label: 'Melancholic', emoji: '🌧️', group: 'Vibe' },
  { value: 'epic', label: 'Epic', emoji: '⚔️', group: 'Vibe' },
  // Genre
  { value: 'pop', label: 'Pop', emoji: '🎵', group: 'Genre' },
  { value: 'rock', label: 'Rock', emoji: '🎸', group: 'Genre' },
  { value: 'indie', label: 'Indie', emoji: '📻', group: 'Genre' },
  { value: 'alternative', label: 'Alternative', emoji: '🌀', group: 'Genre' },
  { value: 'metal', label: 'Metal', emoji: '🤘', group: 'Genre' },
  { value: 'punk', label: 'Punk', emoji: '🧷', group: 'Genre' },
  { value: 'hip-hop', label: 'Hip-Hop', emoji: '🎤', group: 'Genre' },
  { value: 'r-and-b', label: 'R&B', emoji: '💜', group: 'Genre' },
  { value: 'soul', label: 'Soul', emoji: '🎷', group: 'Genre' },
  { value: 'funk', label: 'Funk', emoji: '🕶️', group: 'Genre' },
  { value: 'jazz', label: 'Jazz', emoji: '🎺', group: 'Genre' },
  { value: 'blues', label: 'Blues', emoji: '🎹', group: 'Genre' },
  { value: 'country', label: 'Country', emoji: '🤠', group: 'Genre' },
  { value: 'folk', label: 'Folk', emoji: '🪕', group: 'Genre' },
  { value: 'acoustic', label: 'Acoustic', emoji: '🪵', group: 'Genre' },
  { value: 'classical', label: 'Classical', emoji: '🎻', group: 'Genre' },
  { value: 'gospel', label: 'Gospel', emoji: '🙌', group: 'Genre' },
  { value: 'reggae', label: 'Reggae', emoji: '🟢', group: 'Genre' },
  { value: 'afrobeats', label: 'Afrobeats', emoji: '🥁', group: 'Genre' },
  { value: 'k-pop', label: 'K-Pop', emoji: '💫', group: 'Genre' },
  { value: 'lo-fi', label: 'Lo-Fi', emoji: '☕', group: 'Genre' },
  { value: 'ambient', label: 'Ambient', emoji: '🌫️', group: 'Genre' },
  // Electronic
  { value: 'electronic', label: 'Electronic', emoji: '⚡', group: 'Electronic' },
  { value: 'house', label: 'House', emoji: '🏠', group: 'Electronic' },
  { value: 'techno', label: 'Techno', emoji: '🔊', group: 'Electronic' },
  { value: 'trance', label: 'Trance', emoji: '🌈', group: 'Electronic' },
  { value: 'drum-and-bass', label: 'Drum & Bass', emoji: '🥁', group: 'Electronic' },
  { value: 'dubstep', label: 'Dubstep', emoji: '💥', group: 'Electronic' },
  { value: 'synthwave', label: 'Synthwave', emoji: '🌆', group: 'Electronic' },
  { value: 'disco', label: 'Disco', emoji: '🪩', group: 'Electronic' },
  // Latin
  { value: 'latin', label: 'Latin', emoji: '💃', group: 'Latin' },
  { value: 'reggaeton', label: 'Reggaeton', emoji: '🔥', group: 'Latin' },
  { value: 'salsa', label: 'Salsa', emoji: '🌶️', group: 'Latin' },
  { value: 'bachata', label: 'Bachata', emoji: '🌹', group: 'Latin' },
  { value: 'cumbia', label: 'Cumbia', emoji: '🪗', group: 'Latin' },
  { value: 'merengue', label: 'Merengue', emoji: '🎊', group: 'Latin' },
  { value: 'flamenco', label: 'Flamenco', emoji: '👠', group: 'Latin' },
  { value: 'rumba', label: 'Rumba', emoji: '🌞', group: 'Latin' },
  { value: 'tango', label: 'Tango', emoji: '🖤', group: 'Latin' },
  // Era
  { value: '70s', label: '70s', emoji: '🕺', group: 'Era' },
  { value: '80s', label: '80s', emoji: '📼', group: 'Era' },
  { value: '90s', label: '90s', emoji: '💿', group: 'Era' },
  { value: '2000s', label: '2000s', emoji: '📱', group: 'Era' },
  { value: 'throwback', label: 'Throwback', emoji: '⏪', group: 'Era' },
  // Other
  { value: 'custom', label: 'Custom', emoji: '✨', group: 'Other' },
] as const;

export type ArenaMood = (typeof ARENA_MOODS)[number]['value'];

export function getMoodLabel(mood: string | null | undefined): string | null {
  const match = ARENA_MOODS.find((m) => m.value === mood);
  return match ? `${match.emoji} ${match.label}` : null;
}

export interface Arena {
  id: string;
  name: string;
  state: ArenaState;
  mood: ArenaMood | null;
  host_id: string | null;
  arena_code: string;
  created_at: string;
}

// arena_code is 6 uppercase hex chars (generate_arena_code). Map the
// look-alikes people actually type (O -> 0, I/L -> 1) and drop anything that
// can't be part of a code.
export function normalizeArenaCode(input: string): string {
  return input
    .toUpperCase()
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1')
    .replace(/[^0-9A-F]/g, '')
    .slice(0, 6);
}

export async function resolveArenaByCode(code: string): Promise<string> {
  const { data, error } = await supabase
    .from('arenas')
    .select('id, state')
    .eq('arena_code', normalizeArenaCode(code))
    .maybeSingle();

  if (error) {
    console.error('Failed to resolve arena by code:', error.message, error);
    throw error;
  }

  // Expired arenas are hidden by RLS, so they also land here
  if (!data) {
    throw new Error('Arena not found');
  }

  if (data.state === 'finished') {
    throw new Error('This arena has ended');
  }

  return data.id;
}

export async function getArena(arenaId: string): Promise<Arena> {
  const { data, error } = await supabase
    .from('arenas')
    .select('*')
    .eq('id', arenaId)
    .single();

  if (error) {
    console.error('Failed to fetch arena:', error.message, error);
    throw error;
  }

  return data as Arena;
}

export async function createArena(name: string, mood: ArenaMood): Promise<Arena> {
  const { data: { session } } = await supabase.auth.getSession();

  if (!session?.user) {
    throw new Error('No authenticated session');
  }

  const trimmed = name.trim();
  const normalizedName =
    trimmed.length > 0 ? trimmed : 'Test Arena';

  // Host is taken from auth.uid() server-side
  const { data: arenaId, error: rpcError } = await supabase
    .rpc('create_arena', { p_name: normalizedName, p_mood: mood });

  if (rpcError) {
    console.error('Failed to create arena:', rpcError.message, rpcError);
    throw rpcError;
  }

  return getArena(arenaId);
}

// Host only. waiting -> active; no-op if already active.
export async function startArenaBattles(arenaId: string): Promise<void> {
  const { error } = await supabase.rpc('start_arena_battles', { p_arena_id: arenaId });

  if (error) {
    console.error('Failed to start arena battles:', error.message, error);
    throw error;
  }
}

// Host only. waiting|active -> finished.
export async function endArena(arenaId: string): Promise<void> {
  const { error } = await supabase.rpc('end_arena', { p_arena_id: arenaId });

  if (error) {
    console.error('Failed to end arena:', error.message, error);
    throw error;
  }
}
