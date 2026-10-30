import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";

export type DerivedBattlePhase = "NORMAL" | "FINAL_30S" | "LOCK_IN" | "SUDDEN_DEATH" | "RESULT" | "FINISHED";

// Mirrors process_battle_lifecycle for display only: lock-in 25 s before the
// end (user decision 2026-10-28). Never used to gate votes or transitions.
export const LOCKIN_LEAD_MS = 25_000;
// "Decisión final" (Paso_2 §2.6): the 30 s before lock-in, when passive votes
// ramp in (passive_vote_config ramp)
export const FINAL_DECISION_MS = 30_000;

// The decided result is revealed this long before the end (user decision
// 2026-10-30): after Sudden Death's close (end − 10 s), so a result decided
// there is already recorded and in the playlist
export const RESULT_REVEAL_LEAD_MS = 4_000;

const battleEndAt = (battle: ArenaBattleView | null): number | null =>
  battle?.started_at && battle.duration_ms ? new Date(battle.started_at).getTime() + battle.duration_ms : null;

// When the decided result is shown
export const getResultRevealAt = (battle: ArenaBattleView | null): number | null => {
  const end = battleEndAt(battle);
  return end === null ? null : end - RESULT_REVEAL_LEAD_MS;
};

// When the "final decision" window starts, from the backend's clock fields
export const getFinalDecisionAt = (battle: ArenaBattleView | null): number | null => {
  const end = battleEndAt(battle);
  return end === null ? null : end - LOCKIN_LEAD_MS - FINAL_DECISION_MS;
};

/**
 * Derives the UI battle phase from BACKEND STATE, for display only (Battle
 * Room and Stage View).
 *
 * Backend-authoritative fields used:
 * - battle.state: 'pending' | 'active' | 'closing' | 'completed'
 * - battle.sudden_death_active: boolean (source of truth for sudden death)
 * - battle.resolution_type / winner_song_id: set when the result is decided
 *   (at lock-in, or when Sudden Death closes 10 s before the end)
 * - started_at / duration_ms: only to time the "final decision" message and
 *   the result's reveal
 *
 * It never triggers state changes.
 */
export const getDerivedBattlePhase = (battle: ArenaBattleView | null, nowMs: number = Date.now()): DerivedBattlePhase => {
  if (!battle) return "NORMAL";
  if (battle.state === "completed") return "FINISHED";
  // resolution_type is only set once decided, so it can't detect an ongoing SD
  if (battle.state === "closing" && battle.sudden_death_active) return "SUDDEN_DEATH";
  // Decided (the winner, or both songs on a draw, already in the playlist) but
  // shown only RESULT_REVEAL_LEAD_MS before the end; until then votes are
  // locked and the result kept for the reveal
  if (battle.state === "closing") {
    const revealAt = getResultRevealAt(battle);
    return battle.resolution_type && (revealAt === null || nowMs >= revealAt) ? "RESULT" : "LOCK_IN";
  }
  const finalAt = getFinalDecisionAt(battle);
  if (battle.state === "active" && finalAt !== null && nowMs >= finalAt) return "FINAL_30S";
  return "NORMAL";
};

// The decided result as a side; null while undecided or for a cancelled battle
export const getResultSide = (battle: ArenaBattleView | null): "A" | "B" | "draw" | null => {
  if (!battle?.resolution_type || battle.resolution_type === "cancelled") return null;
  if (battle.resolution_type === "draw") return "draw";
  if (battle.winner_song_id && battle.winner_song_id === battle.song_a_id) return "A";
  if (battle.winner_song_id && battle.winner_song_id === battle.song_b_id) return "B";
  return null;
};
