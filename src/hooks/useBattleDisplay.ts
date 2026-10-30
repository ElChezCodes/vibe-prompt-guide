import { useEffect, useReducer, useRef } from "react";
import { ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { DerivedBattlePhase, getDerivedBattlePhase, getFinalDecisionAt } from "@/lib/derivedBattlePhase";

// How long a finished battle stays on screen once the next one exists: the
// winner fades out, then "Preparing next battle" (Paso_2 §6.2 steps 5-6)
export const BATTLE_HOLD_MS = 1100;

/**
 * Display-only view of the backend battle for the Battle Room and the Stage
 * View. The backend completes a battle and creates the next one in the same
 * statement, so without this the finished battle would vanish at once: the
 * previous battle stays on screen (as completed) for BATTLE_HOLD_MS. Also
 * re-renders when the "final decision" window opens (a time-based display
 * phase). Decides nothing: voting stays gated on the live battle's state.
 */
export const useBattleDisplay = (battle: ArenaBattleView | null, pausedAt: string | null = null) => {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  const lastRef = useRef<ArenaBattleView | null>(null);
  const holdRef = useRef<{ battle: ArenaBattleView; until: number } | null>(null);
  const now = Date.now();

  const prev = lastRef.current;
  if (battle && prev && battle.battle_id !== prev.battle_id && (prev.state === "closing" || prev.state === "completed")) {
    // A new battle only follows a completed one
    holdRef.current = { battle: { ...prev, state: "completed" }, until: now + BATTLE_HOLD_MS };
  }
  if (battle) lastRef.current = battle;

  const hold = holdRef.current && holdRef.current.until > now ? holdRef.current : null;
  const displayBattle = hold ? hold.battle : battle;

  const holdUntil = hold?.until ?? null;
  useEffect(() => {
    if (holdUntil === null) return;
    const t = setTimeout(rerender, Math.max(0, holdUntil - Date.now()));
    return () => clearTimeout(t);
  }, [holdUntil]);

  // Paused: the backend clock is frozen, so is the display
  const phaseNow = pausedAt ? new Date(pausedAt).getTime() : now;
  const phase: DerivedBattlePhase = getDerivedBattlePhase(displayBattle, phaseNow);

  const finalAt = getFinalDecisionAt(displayBattle);
  useEffect(() => {
    if (pausedAt || phase !== "NORMAL" || displayBattle?.state !== "active" || finalAt === null) return;
    const wait = finalAt - Date.now();
    if (wait <= 0) return;
    const t = setTimeout(rerender, wait + 20);
    return () => clearTimeout(t);
  }, [finalAt, phase, pausedAt, displayBattle?.state]);

  return {
    battle: displayBattle,
    phase,
    // The shown battle is the live one (only then may it take votes)
    isLive: !!displayBattle && displayBattle.battle_id === battle?.battle_id,
    preparingNext: !!hold,
  };
};
