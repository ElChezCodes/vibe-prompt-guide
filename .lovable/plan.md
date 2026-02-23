

# Instrument UI for End-of-Battle Phase Desynchronization Analysis

This is a diagnostic-only change. No business logic, lifecycle, or styling will be modified. We are adding structured console logging to four files to capture precise timing data.

## Changes

### 1. BattleTimer.tsx -- Instrument `updateRemaining()`

Inside the `updateRemaining` function (line 37-40), add a structured log that outputs:
- `battle_id`, `state`, `started_at`, `duration_ms`
- Computed `elapsedMs`, `remainingMs`, `remaining_seconds`
- `client_now` (Date.now())

This requires inlining the computation (currently delegated to `getRemainingSecondsFromBattle`) so individual values are accessible for logging. The calculation itself remains identical.

### 2. BattleRoomScreen.tsx -- Instrument `getDerivedBattlePhase()`

Before each `return` statement in `getDerivedBattlePhase` (lines 40-57), add a structured log with:
- `battle_id`, `state`, `lockin_at`, `resolution_type`
- The `returned_phase` value
- `Date.now()`

### 3. useBattleOrchestrator.ts -- Instrument Realtime callback

At the top of the Realtime subscription callback (after line 158, before the INSERT/UPDATE branches), add a structured log with:
- `eventType`
- `payload.new.id`, `payload.new.state`, `payload.new.lockin_at`, `payload.new.winner_song_id`
- `Date.now()`

### 4. StageView.tsx -- Instrument render

At the top of the `StageView` component body (line 32), add a structured log with:
- `battle?.battle_id`, `battle?.state`
- `derivedPhase`
- `Date.now()`

## Technical Details

All logs use a consistent bracketed prefix format (`[BattleTimer Debug]`, `[DerivedPhase Debug]`, `[Realtime Debug]`, `[StageView Render]`) for easy filtering in DevTools.

No state, props, effects, intervals, or rendering logic will be altered. Only `console.log` statements are added.

Files modified:
- `src/components/battle/BattleTimer.tsx`
- `src/screens/BattleRoomScreen.tsx`
- `src/hooks/useBattleOrchestrator.ts`
- `src/components/battle/StageView.tsx`

