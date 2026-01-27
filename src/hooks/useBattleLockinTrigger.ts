import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

interface BattleForLockinTrigger {
  id: string;
  state: string;
  started_at: string;
  duration_ms: number;
  lockin_at?: string | null;
}

/**
 * useBattleLockinTrigger
 *
 * A backend-authoritative signal emitter that sends "wake-up" hints
 * to the backend when a battle MAY be approaching lock-in.
 *
 * SEMANTICS:
 * - This is a NEUTRAL HINT to the backend, not an assertion.
 * - The backend is the SOLE AUTHORITY for lock-in decisions.
 * - Multiple clients may signal safely; backend handles idempotency.
 * - We throttle to avoid spamming, but allow periodic rechecks.
 *
 * STOP CONDITIONS:
 * - battle.lockin_at becomes non-null (backend confirmed lock-in)
 * - battle.state !== "active"
 */
export function useBattleLockinTrigger(battle: BattleForLockinTrigger | null): void {
  // Throttle: stores timestamp of last signal per battle
  const lastSignalRef = useRef<{ battleId: string; timestamp: number } | null>(null);

  useEffect(() => {
    // ─────────────────────────────────────────────
    // STOP CONDITIONS: Do not signal if:
    // - No battle
    // - Battle not active
    // - Backend already confirmed lock-in (lockin_at is set)
    // ─────────────────────────────────────────────
    if (!battle) return;
    if (battle.state !== "active") return;
    if (battle.lockin_at !== null && battle.lockin_at !== undefined) return;

    // ─────────────────────────────────────────────
    // LOCAL ESTIMATE: Check if we're in the lock-in window
    // This is a HINT only, NOT a decision.
    // Uses started_at + duration_ms directly (NOT remainingTime from UI)
    // ─────────────────────────────────────────────
    const LOCKIN_WINDOW_MS = 15000; // Last 15 seconds

    const startedAt = new Date(battle.started_at).getTime();
    const endTime = startedAt + battle.duration_ms;
    const lockinThreshold = endTime - LOCKIN_WINDOW_MS;
    const now = Date.now();

    // Not yet in the lock-in window estimate
    if (now < lockinThreshold) return;

    // ─────────────────────────────────────────────
    // THROTTLE: Avoid spamming the backend
    // Allow re-signaling every 5 seconds
    // ─────────────────────────────────────────────
    const THROTTLE_MS = 5000;

    if (
      lastSignalRef.current &&
      lastSignalRef.current.battleId === battle.id &&
      now - lastSignalRef.current.timestamp < THROTTLE_MS
    ) {
      return;
    }

    // Record this signal attempt
    lastSignalRef.current = { battleId: battle.id, timestamp: now };

    // 🔍 Observability: neutral signal, not a state assertion
    console.log("[useBattleLockinTrigger] signal", {
      battleId: battle.id,
      note: "Hint to backend; backend decides lock-in",
      now,
    });

    const signalBattleLockin = async () => {
      try {
        const { data: sessionData } = await supabase.auth.getSession();
        const accessToken = sessionData?.session?.access_token;

        const response = await fetch(
          `${
            import.meta.env.VITE_SUPABASE_URL ?? "https://uuxzjroikbzwaszpgiks.supabase.co"
          }/functions/v1/battle-lockin`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...(accessToken && {
                Authorization: `Bearer ${accessToken}`,
              }),
            },
            body: JSON.stringify({ battle_id: battle.id }),
          },
        );

        // 200 = processed, 409 = already handled or not yet eligible — both are expected
        if (response.status === 200 || response.status === 409) {
          return;
        }

        console.warn("[useBattleLockinTrigger] unexpected response:", response.status);
      } catch (error) {
        console.warn("[useBattleLockinTrigger] request failed:", error);
      }
    };

    signalBattleLockin();
  }, [battle?.id, battle?.state, battle?.started_at, battle?.duration_ms, battle?.lockin_at]);
}
