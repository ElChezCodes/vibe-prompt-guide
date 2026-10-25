import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js";

/**
 * ─────────────────────────────────────────────
 * CORS CONFIGURATION
 * ─────────────────────────────────────────────
 */
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/**
 * Helper canónico para respuestas de error
 */
function errorResponse(error: string, status: number) {
  return new Response(JSON.stringify({ ok: false, error }), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
    },
  });
}

/**
 * Validador UUID v4
 */
function isValidUUID(value: string): boolean {
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(value);
}

/**
 * ─────────────────────────────────────────────
 * EDGE FUNCTION — NOTIFIER ONLY
 * ─────────────────────────────────────────────
 */
serve(async (req) => {
  try {
    console.log("[battle-lockin][request]", { method: req.method });

    // 0) CORS
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    // 1) METHOD
    if (req.method !== "POST") {
      return errorResponse("METHOD_NOT_ALLOWED", 405);
    }

    // 2) CONTENT TYPE
    const contentType = req.headers.get("content-type");
    if (!contentType || !contentType.includes("application/json")) {
      return errorResponse("INVALID_CONTENT_TYPE", 415);
    }

    // 3) BODY
    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return errorResponse("MISSING_BODY", 400);
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return errorResponse("INVALID_BODY", 400);
    }

    const payload = body as Record<string, unknown>;

    if (!("battle_id" in payload)) {
      return errorResponse("MISSING_BATTLE_ID", 400);
    }

    const battleId = payload["battle_id"];
    if (typeof battleId !== "string" || !isValidUUID(battleId)) {
      return errorResponse("INVALID_BATTLE_ID", 400);
    }

    // 4) AUTH
    const authHeader = req.headers.get("authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return errorResponse("MISSING_AUTHORIZATION_HEADER", 401);
    }

    const token = authHeader.replace("Bearer ", "");

    // 5) SUPABASE CLIENT
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // 6) JWT VALIDATION
    const { data: authData, error: authError } =
      await supabase.auth.getUser(token);

    if (authError || !authData?.user) {
      return errorResponse("INVALID_JWT", 401);
    }

    console.log("[battle-lockin][auth]", { userId: authData.user.id });

    // 7) READ BATTLE (OBSERVATION ONLY)
    const { data: battle, error: battleError } = await supabase
      .from("battles")
      .select(
        `
        id,
        state,
        started_at,
        duration_ms,
        lockin_at,
        sudden_death_active,
        winner_song_id
      `
      )
      .eq("id", battleId)
      .single();

    if (battleError || !battle) {
      return errorResponse("BATTLE_NOT_FOUND", 404);
    }

    // 8) TIME CALCULATION (NO SIDE EFFECTS)
    const endAt =
      new Date(battle.started_at).getTime() + battle.duration_ms;
    const lockinAt = endAt - 15_000;

    console.log("[battle-lockin][time-check]", {
      now: Date.now(),
      lockinAt,
      endAt,
    });

    // 9) FINAL NOTIFIER RESPONSE
    console.log("[battle-lockin][notify]", {
      battle_id: battle.id,
      state: battle.state,
      lockin_at: battle.lockin_at,
      sudden_death_active: battle.sudden_death_active,
      winner_song_id: battle.winner_song_id,
    });

    return new Response(
      JSON.stringify({
        ok: true,
        role: "notifier",
        battle_id: battle.id,
        state: battle.state,
        lockin_at: battle.lockin_at,
        sudden_death_active: battle.sudden_death_active,
        winner_song_id: battle.winner_song_id,
      }),
      {
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders,
        },
      }
    );
  } catch (err) {
    console.error("[battle-lockin][uncaught]", err);
    return errorResponse("INTERNAL_ERROR", 500);
  }
});