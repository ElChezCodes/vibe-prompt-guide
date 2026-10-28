/**
 * Battle Closure Orchestrator - Backend-Authoritative Design
 *
 * DISPLAY-ONLY utilities for the frontend.
 * Backend is the single source of truth for:
 * - Lock-in
 * - Sudden death
 * - Winner determination
 * - Battle resolution
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
  lockin_at: string | null;
  sudden_death_active: boolean;
  winner_song_id: string | null;
  sudden_death_started_at: string | null;
}

/**
 * Fetches the current battle state from the backend.
 * This is the ONLY source of truth for battle state.
 */
export async function fetchBattle(battleId: string): Promise<BattleData | null> {
  const { data, error } = await supabase
    .from("battles")
    .select(
      `
      id,
      arena_id,
      song_a_id,
      song_b_id,
      state,
      started_at,
      lockin_at,
      sudden_death_active,
      winner_song_id,
      sudden_death_started_at
      `,
    )
    .eq("id", battleId)
    .single();

  if (error || !data) {
    console.error("[Closure] Failed to fetch battle", error);
    return null;
  }

  return data as BattleData;
}

/**
 * Derives the voting phase from backend battle state.
 * PURELY reactive — no local computation.
 */
export function deriveVotingPhaseFromBattle(battle: BattleData): "active" | "locked" | "sudden_death" | "closed" {
  if (battle.state === "completed") {
    return "closed";
  }

  if (battle.state === "closing") {
    if (battle.sudden_death_active) {
      return "sudden_death";
    }
    return "locked";
  }

  if (battle.state !== "active") {
    return "closed";
  }

  return "active";
}

/**
 * Checks if the battle is in sudden death phase.
 * Derived ONLY from backend state.
 */
export function isSuddenDeathActiveFromBattle(battle: BattleData): boolean {
  return battle.state === "closing" && battle.sudden_death_active === true;
}

/**
 * Checks if the battle is locked (regular voting frozen).
 * Derived ONLY from backend state.
 */
export function isLockedFromBattle(battle: BattleData): boolean {
  return battle.state === "closing";
}

/**
 * Checks if the battle is resolved.
 * Derived ONLY from backend state.
 */
export function isResolvedFromBattle(battle: BattleData): boolean {
  return battle.state === "completed";
}

/**
 * Gets winner information from backend state.
 * NO local vote counting.
 */
export function getWinnerFromBattle(battle: BattleData): {
  winnerId: string | null;
  winnerSide: "A" | "B" | null;
  isDraw: boolean;
  bothSongsWin: boolean;
} {
  if (battle.state !== "completed") {
    return {
      winnerId: null,
      winnerSide: null,
      isDraw: false,
      bothSongsWin: false,
    };
  }

  const isDraw = battle.winner_song_id === null;
  // A draw always means both songs got queued (finalize_and_enqueue_battle /
  // process_battle_lifecycle always insert both songs into playlist_queue on
  // a tie), so bothSongsWin is just isDraw — no separate signal needed.
  const bothSongsWin = isDraw;

  let winnerSide: "A" | "B" | null = null;

  if (battle.winner_song_id) {
    if (battle.winner_song_id === battle.song_a_id) {
      winnerSide = "A";
    } else if (battle.winner_song_id === battle.song_b_id) {
      winnerSide = "B";
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
 * Triggered by realtime subscriptions or polling.
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
  console.log(`[Closure] Emitted battle:closed for battle ${battleId}`);
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
  console.log(`[Closure] Emitted battle:lockin_reached for battle ${battleId}, suddenDeath=${suddenDeathActive}`);
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
  console.log(`[Closure] Emitted battle:sudden_death_started for battle ${battleId}`);
}

// DISPLAY-ONLY constants
// Step 18: 10 s, from lock-in (end - 15 s) to end - 5 s (v4 §5.3)
const SUDDEN_DEATH_DURATION_MS = 10_000;
const LOCKIN_OFFSET_MS = 15_000;

export function getSuddenDeathDurationMs(): number {
  return SUDDEN_DEATH_DURATION_MS;
}

export function getLockinOffsetMs(): number {
  return LOCKIN_OFFSET_MS;
}
