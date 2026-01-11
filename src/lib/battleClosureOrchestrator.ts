/**
 * Battle Closure Orchestrator - Logical Layer
 * 
 * Responsible for:
 * - Handling LOCK-IN event
 * - Deciding Sudden Death activation
 * - Counting final votes
 * - Resolving the winner
 * - Executing side effects
 * - Closing the battle deterministically
 * 
 * This module does NOT:
 * - Register votes (delegated to Voting Layer)
 * - Depend on UI
 * - Manage timers
 */

import { supabase } from "@/integrations/supabase/client";

// ============= Types =============

export type BattlePhase = 'active' | 'locked' | 'sudden_death' | 'closing' | 'completed';

export interface BattleClosureState {
  battleId: string;
  phase: BattlePhase;
  lockedAt: string | null;
  suddenDeathActive: boolean;
  normalVotesA: number;
  normalVotesB: number;
  suddenDeathVotesA: number;
  suddenDeathVotesB: number;
  winner: 'A' | 'B' | 'draw' | null;
  resolvedAt: string | null;
}

export interface VoteAggregate {
  songACount: number;
  songBCount: number;
}

export interface BattleClosureEvent {
  type: 'LOCK_IN' | 'SUDDEN_DEATH_VOTE' | 'BATTLE_TIMER_ENDED';
  battleId: string;
  payload?: {
    participantId?: string;
    songId?: string;
    arenaId?: string;
    identityAnchorId?: string;
  };
}

export interface ClosureResult {
  success: boolean;
  state: BattleClosureState;
  error?: string;
}

// ============= State Factory =============

export function createInitialClosureState(battleId: string): BattleClosureState {
  return {
    battleId,
    phase: 'active',
    lockedAt: null,
    suddenDeathActive: false,
    normalVotesA: 0,
    normalVotesB: 0,
    suddenDeathVotesA: 0,
    suddenDeathVotesB: 0,
    winner: null,
    resolvedAt: null,
  };
}

// ============= Vote Counting =============

/**
 * Count active votes for a battle, optionally filtered by timestamp
 * RULE: Only counts votes with status = 'active'
 */
export async function countVotes(
  battleId: string,
  songAId: string,
  songBId: string,
  beforeTimestamp?: string
): Promise<VoteAggregate | null> {
  let queryA = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songAId)
    .eq('status', 'active');

  let queryB = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songBId)
    .eq('status', 'active');

  // Filter by timestamp if provided (for normal votes before lock-in)
  if (beforeTimestamp) {
    queryA = queryA.lte('created_at', beforeTimestamp);
    queryB = queryB.lte('created_at', beforeTimestamp);
  }

  const [resultA, resultB] = await Promise.all([queryA, queryB]);

  if (resultA.error || resultB.error) {
    console.error('[ClosureOrchestrator] Failed to count votes:', resultA.error, resultB.error);
    return null;
  }

  return {
    songACount: resultA.count ?? 0,
    songBCount: resultB.count ?? 0,
  };
}

/**
 * Count Sudden Death votes (votes created AFTER lock-in)
 */
export async function countSuddenDeathVotes(
  battleId: string,
  songAId: string,
  songBId: string,
  afterTimestamp: string
): Promise<VoteAggregate | null> {
  const [resultA, resultB] = await Promise.all([
    supabase
      .from('votes')
      .select('*', { count: 'exact', head: true })
      .eq('battle_id', battleId)
      .eq('song_id', songAId)
      .eq('status', 'active')
      .gt('created_at', afterTimestamp),
    supabase
      .from('votes')
      .select('*', { count: 'exact', head: true })
      .eq('battle_id', battleId)
      .eq('song_id', songBId)
      .eq('status', 'active')
      .gt('created_at', afterTimestamp),
  ]);

  if (resultA.error || resultB.error) {
    console.error('[ClosureOrchestrator] Failed to count SD votes:', resultA.error, resultB.error);
    return null;
  }

  return {
    songACount: resultA.count ?? 0,
    songBCount: resultB.count ?? 0,
  };
}

// ============= Tie Detection =============

/**
 * RULE: Sudden Death is activated ONLY if there is an EXACT total tie at LOCK-IN
 */
export function isTied(aggregate: VoteAggregate): boolean {
  return aggregate.songACount === aggregate.songBCount;
}

// ============= Winner Resolution =============

/**
 * Resolve winner based on total votes
 */
export function resolveWinner(
  normalA: number,
  normalB: number,
  sdA: number,
  sdB: number
): 'A' | 'B' | 'draw' {
  const totalA = normalA + sdA;
  const totalB = normalB + sdB;

  if (totalA > totalB) return 'A';
  if (totalB > totalA) return 'B';
  return 'draw';
}

// ============= Sudden Death Validation =============

/**
 * Check if a participant has already voted in Sudden Death
 */
export async function hasSuddenDeathVote(
  battleId: string,
  participantId: string,
  afterTimestamp: string
): Promise<boolean> {
  const { count, error } = await supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('participant_id', participantId)
    .gt('created_at', afterTimestamp);

  if (error) {
    console.error('[ClosureOrchestrator] Failed to check SD vote:', error);
    return true; // Block on error for safety
  }

  return (count ?? 0) > 0;
}

// ============= Event Handlers =============

/**
 * Handle LOCK_IN event
 * - Capture locked_at timestamp
 * - Freeze normal voting via state change
 * - Evaluate tie for Sudden Death
 */
export async function handleLockIn(
  state: BattleClosureState,
  songAId: string,
  songBId: string
): Promise<ClosureResult> {
  if (state.phase !== 'active') {
    return { 
      success: false, 
      state, 
      error: `Invalid phase for LOCK_IN: ${state.phase}` 
    };
  }

  const lockedAt = new Date().toISOString();

  // Count votes at moment of lock-in
  const aggregate = await countVotes(state.battleId, songAId, songBId, lockedAt);
  
  if (!aggregate) {
    return { 
      success: false, 
      state, 
      error: 'Failed to count votes at lock-in' 
    };
  }

  // RULE: Sudden Death activated ONLY on exact tie
  const suddenDeathActive = isTied(aggregate);

  const newState: BattleClosureState = {
    ...state,
    phase: suddenDeathActive ? 'sudden_death' : 'locked',
    lockedAt,
    suddenDeathActive,
    normalVotesA: aggregate.songACount,
    normalVotesB: aggregate.songBCount,
  };

  console.log('[ClosureOrchestrator] LOCK_IN processed:', {
    lockedAt,
    normalVotesA: aggregate.songACount,
    normalVotesB: aggregate.songBCount,
    suddenDeathActive,
  });

  return { success: true, state: newState };
}

/**
 * Handle BATTLE_TIMER_ENDED event
 * - Count final votes (normal + Sudden Death if active)
 * - Resolve winner
 * - Execute side effects
 * - Mark battle as completed
 */
export async function handleBattleTimerEnded(
  state: BattleClosureState,
  songAId: string,
  songBId: string
): Promise<ClosureResult> {
  if (state.phase !== 'locked' && state.phase !== 'sudden_death') {
    return { 
      success: false, 
      state, 
      error: `Invalid phase for BATTLE_TIMER_ENDED: ${state.phase}` 
    };
  }

  // Transition to closing phase
  let newState: BattleClosureState = { ...state, phase: 'closing' };

  // Count Sudden Death votes if active
  let sdVotesA = 0;
  let sdVotesB = 0;

  if (state.suddenDeathActive && state.lockedAt) {
    const sdAggregate = await countSuddenDeathVotes(
      state.battleId,
      songAId,
      songBId,
      state.lockedAt
    );

    if (sdAggregate) {
      sdVotesA = sdAggregate.songACount;
      sdVotesB = sdAggregate.songBCount;
    }
  }

  // Resolve winner
  const winner = resolveWinner(
    state.normalVotesA,
    state.normalVotesB,
    sdVotesA,
    sdVotesB
  );

  const resolvedAt = new Date().toISOString();

  newState = {
    ...newState,
    suddenDeathVotesA: sdVotesA,
    suddenDeathVotesB: sdVotesB,
    winner,
    resolvedAt,
    phase: 'completed',
  };

  // Execute side effects in strict order
  await executeSideEffects(newState, songAId, songBId);

  console.log('[ClosureOrchestrator] BATTLE_TIMER_ENDED processed:', {
    normalVotesA: state.normalVotesA,
    normalVotesB: state.normalVotesB,
    suddenDeathVotesA: sdVotesA,
    suddenDeathVotesB: sdVotesB,
    winner,
    resolvedAt,
  });

  return { success: true, state: newState };
}

// ============= Side Effects =============

/**
 * Execute side effects in strict order:
 * 1. Enqueue winning song (if winner exists)
 * 2. Emit BATTLE_ENDED event (abstract)
 * 3. Update statistics (placeholder)
 * 4. Cleanup (placeholder)
 */
async function executeSideEffects(
  state: BattleClosureState,
  songAId: string,
  songBId: string
): Promise<void> {
  // 1. Enqueue winning song (only if winner, not draw)
  if (state.winner && state.winner !== 'draw') {
    const winningSongId = state.winner === 'A' ? songAId : songBId;
    await enqueueWinningSong(state.battleId, winningSongId);
  }

  // 2. Emit BATTLE_ENDED event (abstract - no Spotify dependency)
  emitBattleEndedEvent(state);

  // 3. Update statistics (placeholder for future implementation)
  // await updateBattleStatistics(state);

  // 4. Cleanup (placeholder for future implementation)
  // await cleanupBattle(state.battleId);
}

/**
 * Enqueue winning song to host playlist
 * Abstract implementation - actual integration TBD
 */
async function enqueueWinningSong(battleId: string, songId: string): Promise<void> {
  console.log('[ClosureOrchestrator] Enqueue winning song:', { battleId, songId });
  // Future: Integrate with streaming provider
}

/**
 * Emit battle ended event for UI consumption
 */
function emitBattleEndedEvent(state: BattleClosureState): void {
  // Use custom event for decoupled UI notification
  const event = new CustomEvent('battle:ended', {
    detail: {
      battleId: state.battleId,
      winner: state.winner,
      normalVotesA: state.normalVotesA,
      normalVotesB: state.normalVotesB,
      suddenDeathVotesA: state.suddenDeathVotesA,
      suddenDeathVotesB: state.suddenDeathVotesB,
      suddenDeathActive: state.suddenDeathActive,
      resolvedAt: state.resolvedAt,
    },
  });
  
  if (typeof window !== 'undefined') {
    window.dispatchEvent(event);
  }

  console.log('[ClosureOrchestrator] BATTLE_ENDED event emitted:', state);
}

// ============= Main Event Dispatcher =============

/**
 * Process a battle closure event
 * Deterministic, event-driven dispatch
 */
export async function processBattleClosureEvent(
  event: BattleClosureEvent,
  currentState: BattleClosureState,
  songAId: string,
  songBId: string
): Promise<ClosureResult> {
  console.log('[ClosureOrchestrator] Processing event:', event.type, { battleId: event.battleId });

  switch (event.type) {
    case 'LOCK_IN':
      return handleLockIn(currentState, songAId, songBId);

    case 'BATTLE_TIMER_ENDED':
      return handleBattleTimerEnded(currentState, songAId, songBId);

    case 'SUDDEN_DEATH_VOTE':
      // Sudden Death votes are delegated to the Voting Layer
      // This orchestrator only validates, does NOT register votes
      return { 
        success: true, 
        state: currentState,
        error: 'SUDDEN_DEATH_VOTE should be handled by Voting Layer' 
      };

    default:
      return { 
        success: false, 
        state: currentState, 
        error: `Unknown event type: ${(event as BattleClosureEvent).type}` 
      };
  }
}

// ============= Sudden Death Vote Validation =============

/**
 * Validate if a Sudden Death vote is allowed
 * RULES:
 * - Battle must be in sudden_death phase
 * - User must be ACTIVE (has valid session)
 * - User has not voted in Sudden Death before
 */
export async function validateSuddenDeathVote(
  state: BattleClosureState,
  participantId: string
): Promise<{ valid: boolean; reason?: string }> {
  // Check phase
  if (state.phase !== 'sudden_death') {
    return { valid: false, reason: 'Not in Sudden Death phase' };
  }

  // Check Sudden Death is active
  if (!state.suddenDeathActive) {
    return { valid: false, reason: 'Sudden Death not active' };
  }

  // Check locked_at exists
  if (!state.lockedAt) {
    return { valid: false, reason: 'No lock-in timestamp' };
  }

  // Check user hasn't voted in Sudden Death
  const hasVoted = await hasSuddenDeathVote(
    state.battleId,
    participantId,
    state.lockedAt
  );

  if (hasVoted) {
    return { valid: false, reason: 'Already voted in Sudden Death' };
  }

  return { valid: true };
}
