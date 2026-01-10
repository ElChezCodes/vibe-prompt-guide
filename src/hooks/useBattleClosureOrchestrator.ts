/**
 * useBattleClosureOrchestrator Hook
 * 
 * React hook wrapper for the Battle Closure Orchestrator.
 * Manages closure context state and exposes event dispatch methods.
 * 
 * This hook:
 * - Maintains closure context (lockedAt, suddenDeathActive, etc.)
 * - Dispatches events to the orchestrator layer
 * - Provides resolution results to consumers
 * 
 * This hook does NOT:
 * - Register votes (Voting Layer responsibility)
 * - Manage timers (existing useBattleOrchestrator responsibility)
 * - Depend on UI state
 */

import { useState, useCallback, useRef } from "react";
import {
  BattleClosureContext,
  BattleResolution,
  LockInResult,
  SuddenDeathVoteResult,
  SideEffectCallbacks,
  handleLockIn,
  handleSuddenDeathVote,
  handleBattleTimerEnded,
  executeSideEffects,
  markBattleCompleted
} from "@/lib/battleClosureOrchestrator";

export type ClosurePhase = 'active' | 'locked' | 'sudden_death' | 'closing' | 'completed';

interface UseBattleClosureOrchestratorReturn {
  // Current state
  phase: ClosurePhase;
  isLocked: boolean;
  isSuddenDeathActive: boolean;
  resolution: BattleResolution | null;
  
  // Event dispatchers
  dispatchLockIn: (battleId: string, songAId: string, songBId: string) => Promise<LockInResult>;
  dispatchSuddenDeathVote: (participantId: string, songId: string, arenaId: string, identityAnchorId: string) => Promise<SuddenDeathVoteResult>;
  dispatchBattleTimerEnded: (callbacks?: SideEffectCallbacks) => Promise<BattleResolution | null>;
  
  // Context management
  initContext: (battleId: string, songAId: string, songBId: string) => void;
  resetContext: () => void;
  getContext: () => BattleClosureContext | null;
}

export const useBattleClosureOrchestrator = (): UseBattleClosureOrchestratorReturn => {
  const [phase, setPhase] = useState<ClosurePhase>('active');
  const [resolution, setResolution] = useState<BattleResolution | null>(null);
  
  const contextRef = useRef<BattleClosureContext | null>(null);

  /**
   * Initialize context for a new battle
   */
  const initContext = useCallback((battleId: string, songAId: string, songBId: string) => {
    contextRef.current = {
      battleId,
      songAId,
      songBId,
      lockedAt: null,
      suddenDeathActive: false,
      suddenDeathVoters: new Set()
    };
    setPhase('active');
    setResolution(null);
  }, []);

  /**
   * Reset context (for battle transitions)
   */
  const resetContext = useCallback(() => {
    contextRef.current = null;
    setPhase('active');
    setResolution(null);
  }, []);

  /**
   * Get current context (for external reads)
   */
  const getContext = useCallback(() => contextRef.current, []);

  /**
   * Dispatch LOCK_IN event
   * Called when T-15s is reached
   */
  const dispatchLockIn = useCallback(async (
    battleId: string,
    songAId: string,
    songBId: string
  ): Promise<LockInResult> => {
    const result = await handleLockIn(battleId, songAId, songBId);
    
    // Update context
    if (contextRef.current) {
      contextRef.current.lockedAt = result.lockedAt;
      contextRef.current.suddenDeathActive = result.suddenDeathActive;
    }
    
    // Update phase
    setPhase(result.suddenDeathActive ? 'sudden_death' : 'locked');
    
    return result;
  }, []);

  /**
   * Dispatch SUDDEN_DEATH_VOTE event
   * Called when a user attempts to vote during Sudden Death
   */
  const dispatchSuddenDeathVote = useCallback(async (
    participantId: string,
    songId: string,
    arenaId: string,
    identityAnchorId: string
  ): Promise<SuddenDeathVoteResult> => {
    if (!contextRef.current) {
      return { success: false, reason: 'not_active' };
    }
    
    return handleSuddenDeathVote(
      contextRef.current,
      participantId,
      songId,
      arenaId,
      identityAnchorId
    );
  }, []);

  /**
   * Dispatch BATTLE_TIMER_ENDED event
   * Called when battle timer reaches zero
   */
  const dispatchBattleTimerEnded = useCallback(async (
    callbacks?: SideEffectCallbacks
  ): Promise<BattleResolution | null> => {
    if (!contextRef.current) {
      console.error('[ClosureHook] No context for battle end');
      return null;
    }
    
    setPhase('closing');
    
    // Execute deterministic closure
    const result = await handleBattleTimerEnded(contextRef.current);
    
    // Execute side effects in strict order
    if (callbacks) {
      await executeSideEffects(result, contextRef.current.battleId, callbacks);
    }
    
    // Mark battle as completed
    await markBattleCompleted(contextRef.current.battleId);
    
    setPhase('completed');
    setResolution(result);
    
    return result;
  }, []);

  return {
    // State
    phase,
    isLocked: phase === 'locked' || phase === 'sudden_death' || phase === 'closing' || phase === 'completed',
    isSuddenDeathActive: phase === 'sudden_death',
    resolution,
    
    // Event dispatchers
    dispatchLockIn,
    dispatchSuddenDeathVote,
    dispatchBattleTimerEnded,
    
    // Context management
    initContext,
    resetContext,
    getContext
  };
};
