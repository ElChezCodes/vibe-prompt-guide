/**
 * Battle Closure Orchestrator
 * 
 * Event-driven layer responsible for:
 * - Handling LOCK-IN (freeze normal votes, capture timestamp)
 * - Deciding Sudden Death activation (ONLY on exact tie)
 * - Counting final votes
 * - Resolving winner deterministically
 * - Executing side effects in strict order
 * 
 * This layer reacts to events - it does NOT create timers or depend on UI.
 */

import { supabase } from "@/integrations/supabase/client";

// ============================================
// TYPES & INTERFACES
// ============================================

export type BattleClosureState = 'active' | 'closing' | 'completed';

export interface LockInResult {
  lockedAt: string;
  songACount: number;
  songBCount: number;
  suddenDeathActive: boolean;
}

export interface SuddenDeathVoteResult {
  success: boolean;
  reason?: 'not_active' | 'already_voted' | 'user_not_active' | 'error';
}

export interface BattleResolution {
  winningSongId: string | null;  // null = draw
  songAFinalCount: number;
  songBFinalCount: number;
  suddenDeathApplied: boolean;
  resolvedAt: string;
}

export interface BattleClosureContext {
  battleId: string;
  songAId: string;
  songBId: string;
  lockedAt: string | null;
  suddenDeathActive: boolean;
  suddenDeathVoters: Set<string>;  // participant IDs who voted in Sudden Death
}

// ============================================
// EVENT TYPES
// ============================================

export type BattleClosureEvent =
  | { type: 'LOCK_IN'; battleId: string }
  | { type: 'SUDDEN_DEATH_VOTE'; battleId: string; participantId: string; songId: string; arenaId: string; identityAnchorId: string }
  | { type: 'BATTLE_TIMER_ENDED'; battleId: string };

// ============================================
// PURE VOTE COUNTING FUNCTIONS
// ============================================

/**
 * Count normal votes (only those created before or at lock-in time)
 * STRICT: Only counts votes where status = 'active'
 */
export async function countNormalVotes(
  battleId: string,
  songAId: string,
  songBId: string,
  lockedAt: string
): Promise<{ songACount: number; songBCount: number }> {
  // Count votes for Song A created before lock-in
  const { count: songACount, error: errorA } = await supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songAId)
    .eq('status', 'active')
    .lte('created_at', lockedAt);

  if (errorA) {
    console.error('[ClosureOrchestrator] Failed to count Song A votes:', errorA);
  }

  // Count votes for Song B created before lock-in
  const { count: songBCount, error: errorB } = await supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songBId)
    .eq('status', 'active')
    .lte('created_at', lockedAt);

  if (errorB) {
    console.error('[ClosureOrchestrator] Failed to count Song B votes:', errorB);
  }

  return {
    songACount: songACount ?? 0,
    songBCount: songBCount ?? 0
  };
}

/**
 * Count Sudden Death votes (only those created after lock-in)
 * These are special votes that bypass normal toggle rules
 */
export async function countSuddenDeathVotes(
  battleId: string,
  songAId: string,
  songBId: string,
  lockedAt: string
): Promise<{ songACount: number; songBCount: number }> {
  // Count SD votes for Song A (created after lock-in)
  const { count: songACount, error: errorA } = await supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songAId)
    .eq('status', 'active')
    .gt('created_at', lockedAt);

  if (errorA) {
    console.error('[ClosureOrchestrator] Failed to count SD Song A votes:', errorA);
  }

  // Count SD votes for Song B (created after lock-in)
  const { count: songBCount, error: errorB } = await supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songBId)
    .eq('status', 'active')
    .gt('created_at', lockedAt);

  if (errorB) {
    console.error('[ClosureOrchestrator] Failed to count SD Song B votes:', errorB);
  }

  return {
    songACount: songACount ?? 0,
    songBCount: songBCount ?? 0
  };
}

// ============================================
// EVENT HANDLERS
// ============================================

/**
 * Handle LOCK_IN event
 * - Captures locked_at timestamp
 * - Freezes normal voting (via Voting Layer awareness)
 * - Evaluates tie to determine Sudden Death activation
 * 
 * RULE: Sudden Death is ONLY activated if there is an EXACT tie
 */
export async function handleLockIn(
  battleId: string,
  songAId: string,
  songBId: string
): Promise<LockInResult> {
  const lockedAt = new Date().toISOString();

  // Get current vote counts at moment of lock-in
  const { songACount, songBCount } = await countNormalVotes(
    battleId,
    songAId,
    songBId,
    lockedAt
  );

  // CANONICAL RULE: Sudden Death ONLY if exact tie
  const suddenDeathActive = songACount === songBCount;

  console.log(`[ClosureOrchestrator] LOCK_IN: A=${songACount}, B=${songBCount}, SD=${suddenDeathActive}`);

  return {
    lockedAt,
    songACount,
    songBCount,
    suddenDeathActive
  };
}

/**
 * Validate and process a Sudden Death vote
 * 
 * RULES:
 * - Battle must still be active
 * - Sudden Death must be active
 * - User must not have already voted in Sudden Death
 * - Registration is delegated to Voting Layer
 */
export async function handleSuddenDeathVote(
  context: BattleClosureContext,
  participantId: string,
  songId: string,
  arenaId: string,
  identityAnchorId: string
): Promise<SuddenDeathVoteResult> {
  // Validate Sudden Death is active
  if (!context.suddenDeathActive) {
    return { success: false, reason: 'not_active' };
  }

  // Validate user hasn't already voted in Sudden Death
  if (context.suddenDeathVoters.has(participantId)) {
    return { success: false, reason: 'already_voted' };
  }

  // Delegate vote registration to Voting Layer (insert new vote)
  const { data, error } = await supabase
    .from('votes')
    .insert({
      battle_id: context.battleId,
      participant_id: participantId,
      song_id: songId,
      status: 'active',
      arena_id: arenaId,
      identity_anchor_id: identityAnchorId
    })
    .select()
    .single();

  if (error) {
    console.error('[ClosureOrchestrator] SD vote failed:', error);
    return { success: false, reason: 'error' };
  }

  // Track this voter
  context.suddenDeathVoters.add(participantId);

  console.log(`[ClosureOrchestrator] SD vote registered: participant=${participantId}, song=${songId}`);

  return { success: true };
}

/**
 * Handle BATTLE_TIMER_ENDED event
 * 
 * Executes full deterministic closure:
 * 1. Count normal votes (created_at <= locked_at)
 * 2. Add Sudden Death votes ONLY if Sudden Death was active
 * 3. Resolve winner or final draw
 * 4. Return resolution (persistence handled by caller)
 */
export async function handleBattleTimerEnded(
  context: BattleClosureContext
): Promise<BattleResolution> {
  if (!context.lockedAt) {
    // If somehow we reach end without lock-in, use current time
    console.warn('[ClosureOrchestrator] No lockedAt timestamp, using now');
    context.lockedAt = new Date().toISOString();
  }

  // Count normal votes (pre-lock-in)
  const normalVotes = await countNormalVotes(
    context.battleId,
    context.songAId,
    context.songBId,
    context.lockedAt
  );

  let songAFinalCount = normalVotes.songACount;
  let songBFinalCount = normalVotes.songBCount;
  let suddenDeathApplied = false;

  // Add Sudden Death votes ONLY if Sudden Death was active
  if (context.suddenDeathActive) {
    const sdVotes = await countSuddenDeathVotes(
      context.battleId,
      context.songAId,
      context.songBId,
      context.lockedAt
    );
    
    songAFinalCount += sdVotes.songACount;
    songBFinalCount += sdVotes.songBCount;
    suddenDeathApplied = true;

    console.log(`[ClosureOrchestrator] SD votes added: A+${sdVotes.songACount}, B+${sdVotes.songBCount}`);
  }

  // Resolve winner deterministically
  let winningSongId: string | null = null;
  if (songAFinalCount > songBFinalCount) {
    winningSongId = context.songAId;
  } else if (songBFinalCount > songAFinalCount) {
    winningSongId = context.songBId;
  }
  // null = draw (no winner)

  const resolution: BattleResolution = {
    winningSongId,
    songAFinalCount,
    songBFinalCount,
    suddenDeathApplied,
    resolvedAt: new Date().toISOString()
  };

  console.log(`[ClosureOrchestrator] Resolution: winner=${winningSongId || 'DRAW'}, A=${songAFinalCount}, B=${songBFinalCount}`);

  return resolution;
}

// ============================================
// SIDE EFFECT EXECUTION (STRICT ORDER)
// ============================================

export interface SideEffectCallbacks {
  onEnqueueWinner?: (songId: string) => Promise<void>;
  onBattleEnded?: (resolution: BattleResolution) => void;
  onUpdateStatistics?: (battleId: string, resolution: BattleResolution) => Promise<void>;
  onCleanup?: () => void;
}

/**
 * Execute side effects in STRICT ORDER
 * 
 * 1. Enqueue winning song into host playlist (only if winner exists)
 * 2. Emit BATTLE_ENDED event to UI
 * 3. Update statistics
 * 4. Cleanup
 */
export async function executeSideEffects(
  resolution: BattleResolution,
  battleId: string,
  callbacks: SideEffectCallbacks
): Promise<void> {
  // 1. Enqueue winner (only if exists)
  if (resolution.winningSongId && callbacks.onEnqueueWinner) {
    try {
      await callbacks.onEnqueueWinner(resolution.winningSongId);
      console.log(`[ClosureOrchestrator] Winner enqueued: ${resolution.winningSongId}`);
    } catch (err) {
      console.error('[ClosureOrchestrator] Failed to enqueue winner:', err);
    }
  }

  // 2. Emit battle ended event
  if (callbacks.onBattleEnded) {
    callbacks.onBattleEnded(resolution);
  }

  // 3. Update statistics
  if (callbacks.onUpdateStatistics) {
    try {
      await callbacks.onUpdateStatistics(battleId, resolution);
    } catch (err) {
      console.error('[ClosureOrchestrator] Failed to update statistics:', err);
    }
  }

  // 4. Cleanup
  if (callbacks.onCleanup) {
    callbacks.onCleanup();
  }
}

/**
 * Mark battle as completed in database
 */
export async function markBattleCompleted(battleId: string): Promise<boolean> {
  const { error } = await supabase
    .from('battles')
    .update({ state: 'completed' })
    .eq('id', battleId);

  if (error) {
    console.error('[ClosureOrchestrator] Failed to mark battle completed:', error);
    return false;
  }

  return true;
}
