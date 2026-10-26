import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ error: "Method Not Allowed" }),
        { status: 405, headers: corsHeaders }
      );
    }

    const body = await req.json().catch(() => null);
    const arena_id = body?.arena_id;

    if (!arena_id) {
      return new Response(
        JSON.stringify({ error: "arena_id is required" }),
        { status: 400, headers: corsHeaders }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!supabaseUrl || !serviceRoleKey || !anonKey) {
      return new Response(
        JSON.stringify({ error: "Server misconfiguration" }),
        { status: 500, headers: corsHeaders }
      );
    }

    // Identify the caller from their own JWT -- the service-role client below
    // bypasses RLS, so host ownership must be checked here explicitly.
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: corsHeaders }
      );
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userError } = await userClient.auth.getUser();

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: corsHeaders }
      );
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: arena, error: arenaError } = await serviceClient
      .from("arenas")
      .select("id, host_id, state")
      .eq("id", arena_id)
      .single();

    if (arenaError || !arena) {
      return new Response(
        JSON.stringify({ error: "Arena not found" }),
        { status: 404, headers: corsHeaders }
      );
    }

    if (arena.host_id !== user.id) {
      return new Response(
        JSON.stringify({ error: "Only the arena host can create battles" }),
        { status: 403, headers: corsHeaders }
      );
    }

    // Also enforced by the trg_battle_requires_active_arena DB trigger
    if (arena.state !== "active") {
      return new Response(
        JSON.stringify({ error: `Arena is ${arena.state}` }),
        { status: 409, headers: corsHeaders }
      );
    }

    const { data: battles, error: battleError } = await serviceClient
      .from("battles")
      .insert({
        arena_id: arena.id,
        sudden_death_active: false,
      })
      .select("id");

    if (battleError || !battles || battles.length === 0) {
      console.error("Battle insert failed:", battleError);
      return new Response(
        JSON.stringify({ error: "Failed to create battle" }),
        { status: 500, headers: corsHeaders }
      );
    }

    const battleId = battles[0].id;

    return new Response(
      JSON.stringify({
        battle_id: battleId,
        status: "created",
      }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    );
  } catch (err) {
    console.error("Unhandled error:", err);
    return new Response(
      JSON.stringify({ error: "Internal Server Error" }),
      { status: 500, headers: corsHeaders }
    );
  }
});