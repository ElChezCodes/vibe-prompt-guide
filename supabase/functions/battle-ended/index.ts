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
 * ─────────────────────────────────────────────
 * Helper canónico para respuestas de error
 * ─────────────────────────────────────────────
 */
function errorResponse(error: string, status: number) {
  return new Response(
    JSON.stringify({ ok: false, error }),
    {
      status,
      headers: {
        "Content-Type": "application/json",
        ...corsHeaders,
      },
    }
  );
}

/**
 * ─────────────────────────────────────────────
 * Validador UUID v4
 * ─────────────────────────────────────────────
 */
function isValidUUID(value: string): boolean {
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(value);
}

/**
 * ─────────────────────────────────────────────
 * EDGE FUNCTION — NOTIFIER PASIVO
 * ─────────────────────────────────────────────
 *
 * Rol:
 * - Observabilidad
 * - Logs
 * - Snapshot del estado actual
 *
 * PROHIBIDO:
 * - Escribir en DB
 * - Decidir ganadores
 * - Cerrar battles
 * - Contar votos
 */
serve(async (req) => {
  try {
    // 0) CORS PREFLIGHT
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    // 1) METHOD VALIDATION
    if (req.method !== "POST") {
      return errorResponse("METHOD_NOT_ALLOWED", 405);
    }

    // 2) CONTENT-TYPE VALIDATION
    const contentType = req.headers.get("content-type");
    if (!contentType || !contentType.toLowerCase().includes("application/json")) {
      return errorResponse("INVALID_CONTENT_TYPE", 415);
    }

    // 3) BODY VALIDATION
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

    // 4) AUTH HEADER REQUIRED
    const authHeader = req.headers.get("authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return errorResponse("MISSING_AUTHORIZATION_HEADER", 401);
    }

    const token = authHeader.replace("Bearer ", "");

    // 5) SUPABASE CLIENT (SERVICE ROLE)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // 6) JWT VALIDATION — EXPLÍCITA
    const { data: authData, error: authError } =
      await supabase.auth.getUser(token);

    if (authError || !authData?.user) {
      return errorResponse("INVALID_JWT", 401);
    }

    console.log("[battle-ended][auth]", {
      userId: authData.user.id,
    });

    // 7) READ BATTLE — SNAPSHOT ONLY
    const { data: battle, error: battleError } = await supabase
      .from("battles")
      .select(`
        id,
        state,
        lockin_at,
        sudden_death_active,
        winner_song_id,
        resolution_type,
        enqueue_done,
        ended_at
      `)
      .eq("id", battleId)
      .single();

    if (battleError || !battle) {
      return errorResponse("BATTLE_NOT_FOUND", 404);
    }

    // 8) OBSERVABILITY LOG
    console.log("[battle-ended][snapshot]", {
      battle_id: battle.id,
      state: battle.state,
      lockin_at: battle.lockin_at,
      sudden_death_active: battle.sudden_death_active,
      winner_song_id: battle.winner_song_id,
      resolution_type: battle.resolution_type,
      enqueue_done: battle.enqueue_done,
      ended_at: battle.ended_at,
    });

    // 9) PASSIVE RESPONSE (NO SIDE EFFECTS)
    return new Response(
      JSON.stringify({
        ok: true,
        battle: {
          id: battle.id,
          state: battle.state,
          lockin_at: battle.lockin_at,
          sudden_death_active: battle.sudden_death_active,
          winner_song_id: battle.winner_song_id,
          resolution_type: battle.resolution_type,
          enqueue_done: battle.enqueue_done,
          ended_at: battle.ended_at,
        },
      }),
      {
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders,
        },
      }
    );
  } catch (err) {
    console.error("[battle-ended][uncaught]", err);
    return errorResponse("INTERNAL_ERROR", 500);
  }
});