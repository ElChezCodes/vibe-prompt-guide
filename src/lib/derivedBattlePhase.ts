import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";

export type DerivedBattlePhase = "NORMAL" | "FINAL_30S" | "LOCK_IN" | "SUDDEN_DEATH" | "FINISHED";

/**
 * Derives the UI battle phase from BACKEND STATE, for display only (Battle
 * Room and Stage View).
 *
 * Backend-authoritative fields used:
 * - battle.state: 'pending' | 'active' | 'closing' | 'completed'
 * - battle.sudden_death_active: boolean (source of truth for sudden death)
 *
 * It never triggers state changes.
 */
export const getDerivedBattlePhase = (battle: ArenaBattleView | null): DerivedBattlePhase => {
  if (!battle) return "NORMAL";
  if (battle.state === "completed") return "FINISHED";
  // resolution_type is only set at completion, so it can't detect an ongoing SD
  if (battle.state === "closing" && battle.sudden_death_active) return "SUDDEN_DEATH";
  if (battle.state === "closing") return "LOCK_IN";
  return "NORMAL";
};
