import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

interface BattleForEndedTrigger {
  id: string;
  state: string;
  lockin_at?: string | null;
}

/**
 * useBattleEndedTrigger
 *
 * A backend-authoritative signal emitter that wakes up the backend
 * ONLY when the battle has confirmed lock-in (via backend state).
 *
 * Triggers when:
 * - battle.state === "closing" OR battle.lockin_at !== null
 *
 * Does NOT trigger based on:
 * - remainingTime
 * - Frontend-derived phases
 * - Timer simulations
 *
 * Backend-authoritative: The Edge Function decides the actual outcome.
 */
export function useBattleEndedTrigger(battle: BattleForEndedTrigger | null): void {
  const triggeredRef = useRef<string | null>(null);

  // ─────────────────────────────────────────────
  // Signal backend when lock-in has been confirmed by backend
  // ─────────────────────────────────────────────
  useEffect(() => {
    if (!battle) {
      return;
    }

    // ONLY trigger when backend has confirmed lock-in:
    // - battle.state === "closing" (backend transitioned to closing)
    // - OR battle.lockin_at is set (backend wrote lock-in timestamp)
    const isLockinConfirmed = battle.state === "closing" || (battle.lockin_at !== null && battle.lockin_at !== undefined);

    if (!isLockinConfirmed) {
      return;
    }

    // Idempotency: don't signal twice for the same battle
    if (triggeredRef.current === battle.id) {
      return;
    }

    triggeredRef.current = battle.id;

    // 🔍 Observability (neutral signal after backend-confirmed lock-in)
    console.log("[battle-ended signal]", {
      battleId: battle.id,
      battleState: battle.state,
      lockinAt: battle.lockin_at,
      now: Date.now(),
    });

    const signalBattleEnded = async () => {
      try {
        const { data: sessionData } = await supabase.auth.getSession();
        const accessToken = sessionData?.session?.access_token;

        const response = await fetch(
          `${
            import.meta.env.VITE_SUPABASE_URL ?? "https://uuxzjroikbzwaszpgiks.supabase.co"
          }/functions/v1/battle-ended`,
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

        // 200 = processed, 409 = already handled — both are success
        if (response.status === 200 || response.status === 409) {
          return;
        }

        console.warn("[useBattleEndedTrigger] Unexpected response status:", response.status);
      } catch (error) {
        console.warn("[useBattleEndedTrigger] Request failed:", error);
      }
    };

    signalBattleEnded();
  }, [battle?.id, battle?.state, battle?.lockin_at]);
}
