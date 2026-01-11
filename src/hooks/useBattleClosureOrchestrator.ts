/**
 * React Hook for Battle Closure Orchestrator
 * 
 * CLIENT-SIDE WRAPPER ONLY.
 * 
 * This hook:
 * - DOES NOT contain business logic
 * - DOES NOT decide Sudden Death
 * - DOES NOT count votes
 * - DOES NOT resolve battles
 * - Reflects state coming from the orchestrator
 * - Exposes current closure phase, resolution, and flags for UI rendering
 * - NEVER acts as source of truth
 * 
 * All authoritative logic lives in battleClosureOrchestrator.ts
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

/**
 * Return type for the closure orchestrator hook
 */
interface UseBattleClosureOrchestratorReturn {
  /** Current closure state (read-only reflection) */
  closureState: BattleClosureState | null;
  /** Whether voting is locked (any phase past 'active') */
  isLocked: boolean;
  /** Whether Sudden Death is currently active */
  isSuddenDeath: boolean;
  /** Resolved winner ('A', 'B', 'draw', or null if not resolved) */
  winner: 'A' | 'B' | 'draw' | null;
  /** Current phase for UI rendering */
  phase: string | null;
  /** Initialize closure state for a new battle */
  initClosure: (battleId: string) => void;
  /** Emit LOCK_IN event (called at T-15s) */
  emitLockIn: (songAId: string, songBId: string) => Promise<ClosureResult | null>;
  /** Emit BATTLE_TIMER_ENDED event (called when timer reaches zero) */
  emitBattleTimerEnded: (songAId: string, songBId: string) => Promise<ClosureResult | null>;
  /** Check if a participant can vote in Sudden Death */
  canVoteSuddenDeath: (participantId: string) => Promise<boolean>;
  /** Reset closure state (for new battle) */
  resetClosure: () => void;
}

/**
 * Hook providing a reactive interface to the closure orchestrator
 * 
 * This is a pure wrapper that:
 * - Manages local React state reflecting the orchestrator state
 * - Exposes methods to trigger orchestrator events
 * - Derives UI flags from state
 */
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
   * Delegates to orchestrator for processing
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
   * Delegates to orchestrator for processing
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
   * Delegates validation to orchestrator
   */
  const canVoteSuddenDeath = useCallback(async (participantId: string): Promise<boolean> => {
    const currentState = stateRef.current;
    if (!currentState) {
      return false;
    }

    const validation = await validateSuddenDeathVote(currentState, participantId);
    return validation.valid;
  }, []);

  // ============= Derived State (UI Flags) =============

  const isLocked = closureState?.phase === 'locked' ||
                   closureState?.phase === 'sudden_death' ||
                   closureState?.phase === 'closing' ||
                   closureState?.phase === 'completed';

  const isSuddenDeath = closureState?.phase === 'sudden_death';

  const winner = closureState?.winner ?? null;

  const phase = closureState?.phase ?? null;

  return {
    closureState,
    isLocked,
    isSuddenDeath,
    winner,
    phase,
    initClosure,
    emitLockIn,
    emitBattleTimerEnded,
    canVoteSuddenDeath,
    resetClosure,
  };
};

// ============= Event Types for UI Consumption =============

/**
 * Detail structure for battle:ended custom event
 */
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
 * Hook to subscribe to battle ended events
 * 
 * This allows UI components to react when a battle ends
 * without coupling to the orchestrator internals
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
