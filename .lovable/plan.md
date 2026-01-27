
# Fix: useBattleLockinTrigger Not Triggering

## Root Cause Analysis

The `useBattleLockinTrigger` hook is not firing because of a **null safety issue** with `started_at`:

1. **Interface Mismatch**: The hook's interface declares `started_at: string` (required), but the actual battle object from `useBattleOrchestrator` has `started_at: string | null`

2. **Missing Null Guard**: Line 50 attempts `new Date(battle.started_at).getTime()` without first checking if `started_at` is null. When `started_at` is null, this creates an invalid date (epoch 0 or NaN) causing the lock-in window calculation to fail silently.

3. **Early Return Condition Missing**: The hook checks `battle.state !== "active"` but a battle that just became active might still have a brief moment where the UI hasn't received the updated `started_at` value.

## Solution

Update `useBattleLockinTrigger.ts` to:

1. Update the interface to accept `started_at: string | null` to match reality
2. Add an explicit null guard for `started_at` before calculations
3. Keep all other logic unchanged

## Technical Changes

### File: `src/hooks/useBattleLockinTrigger.ts`

**Change 1: Update interface (line 7)**
```typescript
// Before
started_at: string;

// After  
started_at: string | null;
```

**Change 2: Add null guard after existing stop conditions (after line 41)**
```typescript
// Add explicit guard for started_at
if (!battle.started_at) return;
```

This ensures the hook only proceeds when:
- Battle exists
- Battle state is "active"  
- Backend hasn't confirmed lock-in yet
- **AND** `started_at` is available for timing calculations

## Why This Fixes the Issue

Currently, when `battle.started_at` is null:
- `new Date(null).getTime()` returns `0` (epoch time)
- `endTime = 0 + 45000` = 45000ms (Jan 1, 1970 00:00:45)
- `lockinThreshold = 45000 - 15000` = 30000ms
- `now` (current timestamp ~1.7 trillion ms) is always > 30000ms
- This means the condition `now < lockinThreshold` is **always false** when `started_at` is null
- So the hook proceeds to throttle check, but the calculation is completely wrong

Wait - actually this means it WOULD try to fire, but with garbage timing. Let me re-examine...

Actually, the real issue is that the effect may fire ONCE before `started_at` is set, record a timestamp in `lastSignalRef`, and then when `started_at` is properly set, the throttle prevents re-signaling for 5 seconds. By that time, if the battle is short (45s), the timing could already be past the lock-in window calculation.

The fix with the null guard ensures we only attempt signaling when we have valid timing data.

## Files to Modify

| File | Change |
|------|--------|
| `src/hooks/useBattleLockinTrigger.ts` | Add null guard for `started_at`, update interface |

## No Changes To

- BattleRoomScreen
- Voting logic  
- Timer display
- useBattleOrchestrator
- useBattleEndedTrigger
