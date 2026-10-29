import { supabase } from '@/integrations/supabase/client';

// Prestige Influence (step 15, supabase/sql/prestige_influence_2026-10-28.sql).
// Awarded only by the backend (battles triggers) into a service-only ledger;
// the frontend just reads totals and leaderboards.

export type PiReason = 'battle_entry' | 'win' | 'tie' | 'sudden_death_bonus' | 'duplicate_half' | 'penalty';

export interface PiAward {
  id: number;
  reason: PiReason;
  delta: number;
  battle_id: string | null;
  created_at: string;
}

export interface MyPi {
  arena_pi: number;
  total_pi: number;
  recent: PiAward[];
}

export const PI_REASON_LABELS: Record<PiReason, string> = {
  battle_entry: 'Your song made it to battle',
  win: 'Your song won',
  tie: 'Draw: your song plays too',
  sudden_death_bonus: 'Sudden Death bonus',
  duplicate_half: 'A song you backed won',
  penalty: 'Penalty',
};

export interface MyProfile {
  nickname: string;
  is_generated: boolean;
  country: string | null;
  suggested_country: string | null;
  is_account: boolean;
  total_pi: number;
  month_pi: number;
}

export interface ArenaPiRow {
  place: number;
  display_name: string;
  pi: number;
  is_me: boolean;
  is_host: boolean;
}

export interface PastArena {
  arena_id: string;
  arena_code: string;
  name: string;
  ended_at: string;
  players: number;
  my_pi: number | null;
  my_place: number | null;
}

export type PiScope = 'world' | 'country';
export type PiPeriod = 'month' | 'all';

export interface GlobalPiRow {
  place: number;
  display_name: string;
  country: string | null;
  pi: number;
  is_me: boolean;
}

export async function getMyPi(arenaId: string): Promise<MyPi | null> {
  const { data, error } = await supabase.rpc('get_my_pi', { p_arena_id: arenaId }).maybeSingle();
  if (error) {
    console.error('Failed to load PI:', error.message);
    return null;
  }
  return (data as MyPi) ?? null;
}

export async function getMyProfile(): Promise<MyProfile | null> {
  const { data, error } = await supabase.rpc('get_my_profile').maybeSingle();
  if (error) {
    console.error('Failed to load profile:', error.message);
    return null;
  }
  return (data as MyProfile) ?? null;
}

// Empty nickname = back to the generated one; empty country = none.
// Errors: invalid_nickname (2-20 characters), invalid_country
export async function updateMyProfile(nickname: string, country: string | null): Promise<void> {
  const { error } = await supabase.rpc('update_my_profile', { p_nickname: nickname, p_country: country ?? '' });
  if (error) throw new Error(error.message);
}

export async function getArenaPiLeaderboard(arenaId: string): Promise<ArenaPiRow[]> {
  const { data, error } = await supabase.rpc('get_arena_pi_leaderboard', { p_arena_id: arenaId });
  if (error) {
    console.error('Failed to load arena ranking:', error.message);
    return [];
  }
  return (data as ArenaPiRow[]) ?? [];
}

export async function getMyPastArenas(): Promise<PastArena[]> {
  const { data, error } = await supabase.rpc('get_my_past_arenas', { p_limit: 20 });
  if (error) {
    console.error('Failed to load past arenas:', error.message);
    return [];
  }
  return (data as PastArena[]) ?? [];
}

// Accounts only. Country scope without p_country uses the caller's declared one
export async function getPiLeaderboard(scope: PiScope, period: PiPeriod): Promise<GlobalPiRow[]> {
  const { data, error } = await supabase.rpc('get_pi_leaderboard', { p_scope: scope, p_period: period });
  if (error) {
    console.error('Failed to load ranking:', error.message);
    return [];
  }
  return (data as GlobalPiRow[]) ?? [];
}
