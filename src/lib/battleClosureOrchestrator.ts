/**
 * Battle Closure Orchestrator - Backend-Authoritative Design
 * 
 * This module provides DISPLAY-ONLY utilities for the frontend.
 * All battle lifecycle decisions are made by the backend:
 * - Lock-in activation
 * - Sudden death activation
 * - Winner determination
 * - Battle resolution
 * 
 * Backend functions (source of truth):
 * - resolve_lockin_and_activate_sd(battle_id)
 * - resolve_battle_after_sudden_death(battle_id)
 * 
 * The frontend MUST NOT:
 * - Compute vote counts for resolution
 * - Determine winners
 * - Detect ties
 * - Activate sudden death
 * - End battles based on local timers
 */

import { supabase } from "@/integrations/supabase/client";

export type BattleState = "pending" | "active" | "closing" | "completed";

export interface BattleData {
  id: string;
  arena_id: string;
  song_a_id: string;
  song_b_id: string;
  state: BattleState;
  started_at: string | null;
  ended_at: string | null;
  locked_at: string | null;
  lockin_at: string | null;
  battle_end_at: string | null;
  sudden_death_active: boolean;
  winner_song_id: string | null;
  had_sudden_death: boolean;
  is_special_battle: boolean;
}

/**
 * Fetches the current battle state from the backend.
 * This is the ONLY source of truth for battle state.
 */
export async function fetchBattle(battleId: string): Promise<BattleData | null> {
  const { data, error } = await supabase
    .from("battles")
    .select(
      "id, arena_id, song_a_id, song_b_id, state, started_at, ended_at, locked_at, lockin_at, battle_end_at, sudden_death_active, winner_song_id, had_sudden_death, is_special_battle",
    )
    .eq("id", battleId)
    .single();

  if (error || !data) {
    console.error("Failed to fetch battle:", error);
    return null;
  }

  return data as BattleData;
}

/**
 * Derives the voting phase from backend battle state.
 * NO local computation - purely reactive to backend fields.
 */
export function deriveVotingPhaseFromBattle(battle: BattleData): 'active' | 'locked' | 'sudden_death' | 'closed' {
  if (battle.state === 'completed' || battle.state === 'closing') {
    return 'closed';
  }

  if (battle.state !== 'active') {
    return 'closed';
  }

  // Backend-authoritative: sudden_death_active takes precedence
  if (battle.sudden_death_active) {
    return 'sudden_death';
  }

  // Backend-authoritative: locked_at indicates lock-in reached
  if (battle.locked_at !== null) {
    return 'locked';
  }

  return 'active';
}

/**
 * Checks if the battle is in sudden death phase.
 * Derived ONLY from backend state.
 */
export function isSuddenDeathActiveFromBattle(battle: BattleData): boolean {
  return battle.sudden_death_active === true;
}

/**
 * Checks if the battle is locked (voting frozen for regular votes).
 * Derived ONLY from backend state.
 */
export function isLockedFromBattle(battle: BattleData): boolean {
  return battle.locked_at !== null;
}

/**
 * Checks if the battle is resolved.
 * Derived ONLY from backend state.
 */
export function isResolvedFromBattle(battle: BattleData): boolean {
  return battle.state === 'completed';
}

/**
 * Gets winner information from backend state.
 * NO local vote counting.
 */
export function getWinnerFromBattle(battle: BattleData): {
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  bothSongsWin: boolean;
} {
  if (battle.state !== 'completed') {
    return { winnerId: null, winnerSide: null, isDraw: false, bothSongsWin: false };
  }

  const isDraw = battle.winner_song_id === null;
  const bothSongsWin = isDraw && battle.had_sudden_death;

  let winnerSide: 'A' | 'B' | null = null;
  if (battle.winner_song_id) {
    if (battle.winner_song_id === battle.song_a_id) {
      winnerSide = 'A';
    } else if (battle.winner_song_id === battle.song_b_id) {
      winnerSide = 'B';
    }
  }

  return {
    winnerId: battle.winner_song_id,
    winnerSide,
    isDraw,
    bothSongsWin,
  };
}

/**
 * Emits a custom event when backend signals battle closure.
 * This is triggered by realtime subscriptions or polling.
 */
export function emitBattleClosedEvent(
  battleId: string,
  winnerId: string | null,
  winnerSide: "A" | "B" | null,
  isDraw: boolean,
  bothSongsWin: boolean,
  hadSuddenDeath: boolean,
): void {
  const event = new CustomEvent("battle:closed", {
    detail: {
      battleId,
      winnerId,
      winnerSide,
      isDraw,
      bothSongsWin,
      hadSuddenDeath,
      timestamp: new Date().toISOString(),
    },
  });
  window.dispatchEvent(event);
  console.log(`[Closure] Emitted battle:closed event for battle ${battleId}`);
}

/**
 * Emits a custom event when backend signals lock-in reached.
 */
export function emitLockinReachedEvent(battleId: string, suddenDeathActive: boolean): void {
  const event = new CustomEvent("battle:lockin_reached", {
    detail: {
      battleId,
      suddenDeathActive,
      timestamp: new Date().toISOString(),
    },
  });
  window.dispatchEvent(event);
  console.log(
    `[Closure] Emitted battle:lockin_reached event for battle ${battleId}, suddenDeath: ${suddenDeathActive}`,
  );
}

/**
 * Emits a custom event when backend signals sudden death started.
 */
export function emitSuddenDeathStartedEvent(battleId: string): void {
  const event = new CustomEvent("battle:sudden_death_started", {
    detail: {
      battleId,
      timestamp: new Date().toISOString(),
    },
  });
  window.dispatchEvent(event);
  console.log(`[Closure] Emitted battle:sudden_death_started event for battle ${battleId}`);
}

// Constants for display purposes only
const SUDDEN_DEATH_DURATION_MS = 15000;
const LOCKIN_OFFSET_MS = 15000;

export function getSuddenDeathDurationMs(): number {
  return SUDDEN_DEATH_DURATION_MS;
}

export function getLockinOffsetMs(): number {
  return LOCKIN_OFFSET_MS;
}
