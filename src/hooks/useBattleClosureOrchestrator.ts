/**
 * React hook for Battle Closure Orchestrator
 * 
 * Provides a reactive interface to the closure orchestrator logic
 * Reacts to events emitted by the existing battle loop
 */

import { useState, useCallback, useRef, useEffect } from 'react';
import {
  BattleClosureState,
  BattleClosureEvent,
  ClosureResult,
  createInitialClosureState,
  processBattleClosureEvent,
  validateSuddenDeathVote,
} from '@/lib/battleClosureOrchestrator';

interface UseBattleClosureOrchestratorReturn {
  closureState: BattleClosureState | null;
  isLocked: boolean;
  isSuddenDeath: boolean;
  winner: 'A' | 'B' | 'draw' | null;
  initClosure: (battleId: string) => void;
  emitLockIn: (songAId: string, songBId: string) => Promise<ClosureResult | null>;
  emitBattleTimerEnded: (songAId: string, songBId: string) => Promise<ClosureResult | null>;
  canVoteSuddenDeath: (participantId: string) => Promise<boolean>;
  resetClosure: () => void;
}

export const useBattleClosureOrchestrator = (): UseBattleClosureOrchestratorReturn => {
  const [closureState, setClosureState] = useState<BattleClosureState | null>(null);
  const stateRef = useRef<BattleClosureState | null>(null);

  // Keep ref in sync with state for async operations
  useEffect(() => {
    stateRef.current = closureState;
  }, [closureState]);

  /**
   * Initialize closure state for a new battle
   */
  const initClosure = useCallback((battleId: string) => {
    const initialState = createInitialClosureState(battleId);
    setClosureState(initialState);
    console.log('[ClosureHook] Initialized for battle:', battleId);
  }, []);

  /**
   * Reset closure state (for new battle)
   */
  const resetClosure = useCallback(() => {
    setClosureState(null);
    console.log('[ClosureHook] Reset');
  }, []);

  /**
   * Emit LOCK_IN event
   * Called at T-15s to freeze normal voting
   */
  const emitLockIn = useCallback(async (
    songAId: string,
    songBId: string
  ): Promise<ClosureResult | null> => {
    const currentState = stateRef.current;
    if (!currentState) {
      console.warn('[ClosureHook] Cannot emit LOCK_IN - no closure state');
      return null;
    }

    const event: BattleClosureEvent = {
      type: 'LOCK_IN',
      battleId: currentState.battleId,
    };

    const result = await processBattleClosureEvent(event, currentState, songAId, songBId);

    if (result.success) {
      setClosureState(result.state);
    } else {
      console.error('[ClosureHook] LOCK_IN failed:', result.error);
    }

    return result;
  }, []);

  /**
   * Emit BATTLE_TIMER_ENDED event
   * Called when battle timer reaches zero
   */
  const emitBattleTimerEnded = useCallback(async (
    songAId: string,
    songBId: string
  ): Promise<ClosureResult | null> => {
    const currentState = stateRef.current;
    if (!currentState) {
      console.warn('[ClosureHook] Cannot emit BATTLE_TIMER_ENDED - no closure state');
      return null;
    }

    const event: BattleClosureEvent = {
      type: 'BATTLE_TIMER_ENDED',
      battleId: currentState.battleId,
    };

    const result = await processBattleClosureEvent(event, currentState, songAId, songBId);

    if (result.success) {
      setClosureState(result.state);
    } else {
      console.error('[ClosureHook] BATTLE_TIMER_ENDED failed:', result.error);
    }

    return result;
  }, []);

  /**
   * Check if a participant can vote in Sudden Death
   */
  const canVoteSuddenDeath = useCallback(async (participantId: string): Promise<boolean> => {
    const currentState = stateRef.current;
    if (!currentState) {
      return false;
    }

    const validation = await validateSuddenDeathVote(currentState, participantId);
    return validation.valid;
  }, []);

  // Derived state
  const isLocked = closureState?.phase === 'locked' || 
                   closureState?.phase === 'sudden_death' || 
                   closureState?.phase === 'closing' ||
                   closureState?.phase === 'completed';

  const isSuddenDeath = closureState?.phase === 'sudden_death';
  
  const winner = closureState?.winner ?? null;

  return {
    closureState,
    isLocked,
    isSuddenDeath,
    winner,
    initClosure,
    emitLockIn,
    emitBattleTimerEnded,
    canVoteSuddenDeath,
    resetClosure,
  };
};

// ============= Event Types for UI Consumption =============

export interface BattleEndedEventDetail {
  battleId: string;
  winner: 'A' | 'B' | 'draw' | null;
  normalVotesA: number;
  normalVotesB: number;
  suddenDeathVotesA: number;
  suddenDeathVotesB: number;
  suddenDeathActive: boolean;
  resolvedAt: string | null;
}

/**
 * Subscribe to battle ended events
 */
export function useBattleEndedListener(
  callback: (detail: BattleEndedEventDetail) => void
): void {
  useEffect(() => {
    const handler = (event: CustomEvent<BattleEndedEventDetail>) => {
      callback(event.detail);
    };

    window.addEventListener('battle:ended', handler as EventListener);
    
    return () => {
      window.removeEventListener('battle:ended', handler as EventListener);
    };
  }, [callback]);
}
