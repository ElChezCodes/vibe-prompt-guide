/**
 * @deprecated
 * battle-ended is no longer part of the battle authority.
 * Closure is handled exclusively by SQL (cron + RPC).
 *
 * This hook is intentionally a NO-OP and kept temporarily
 * to avoid breaking imports while technical debt is removed incrementally.
 */
export function useBattleEndedTrigger(
  _battleId: string | null,
  _remainingTime: number
): void {
  // Intentionally empty
}
