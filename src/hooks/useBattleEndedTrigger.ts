import { useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

/**
 * Triggers the backend battle-ended signal.
 *
 * IMPORTANT:
 * - This hook DOES NOT decide battle resolution.
 * - It only emits a single signal when the local clock reaches zero.
 * - Backend remains the sole authority.
 */

export function useBattleEndedTrigger(battleId: string | null, remainingSeconds: number): void {
  const hasTriggeredRef = useRef<string | null>(null);

  useEffect(() => {
    if (!battleId) {
      hasTriggeredRef.current = null;
      return;
    }

    // Only trigger when local clock reaches zero
    if (remainingSeconds > 0) {
      return;
    }

    // Prevent duplicate triggers for same battle
    if (hasTriggeredRef.current === battleId) {
      return;
    }

    hasTriggeredRef.current = battleId;

    console.log("[battle-ended trigger] sending signal", {
      battleId,
      remainingSeconds,
      now: Date.now(),
    });

    const triggerBattleEnded = async () => {
      try {
        const { data } = await supabase.auth.getSession();
        const accessToken = data?.session?.access_token;

        await fetch(
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
            body: JSON.stringify({ battle_id: battleId }),
          },
        );
      } catch (error) {
        console.warn("[useBattleEndedTrigger] request failed", error);
      }
    };

    triggerBattleEnded();
  }, [battleId, remainingSeconds]);
}
