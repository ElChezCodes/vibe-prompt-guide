// MusicBrainz payloads are untyped JSON from an outside service
/* eslint-disable @typescript-eslint/no-explicit-any */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * musicbrainz-enrich (roadmap step 8, supabase/sql/affinity_passive_vote_2026-10-27.sql)
 *
 * Maps the ISRCs of the arenas' songs to MusicBrainz open data (recording and
 * artist MBIDs, genres/tags, artist relations), the only song features the
 * affinity profile uses: never Spotify metadata (Developer Policy III.13/III.14).
 *
 * Called by pg_cron (musicbrainz_enrich_job, every minute while there is
 * work) with the same x-watch-secret as spotify-host's watcher
 * (SPOTIFY_WATCH_SECRET; Edge secrets are project-wide). One run at a time
 * (mb_enrich_begin lease), <= 1 request/s (MusicBrainz API rules), each run
 * stops after RUN_BUDGET_MS so the next minute's call doesn't overlap.
 */

const MB = "https://musicbrainz.org/ws/2";
// MusicBrainz asks for an identifying User-Agent with a contact
const USER_AGENT = "MusicFighter/0.1 ( https://creative-cue-codex.lovable.app )";
const REQUEST_GAP_MS = 1_100;
const RUN_BUDGET_MS = 45_000;
const MAX_TAGS = 8;
const MAX_RELATED = 30;
// Artist relations that mean "same musical circle"
const RELATED_TYPES = new Set([
  "member of band",
  "collaboration",
  "subgroup",
  "is person",
  "supporting musician",
  "vocal supporting musician",
  "instrumental supporting musician",
]);

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

class RateLimited extends Error {}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

let lastRequestAt = 0;

// null = 404 (MusicBrainz doesn't know it)
async function mbGet(path: string): Promise<any | null> {
  const wait = lastRequestAt + REQUEST_GAP_MS - Date.now();
  if (wait > 0) await sleep(wait);
  lastRequestAt = Date.now();
  const res = await fetch(`${MB}${path}`, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  if (res.status === 404) return null;
  if (res.status === 503 || res.status === 429) throw new RateLimited(`MusicBrainz ${res.status}`);
  if (!res.ok) throw new Error(`MusicBrainz ${res.status}`);
  return await res.json();
}

// Curated genres first; folksonomy tags (by votes) only when there are none
function pickTags(entity: any): string[] {
  const genres = (entity?.genres ?? []).map((g: any) => String(g.name).toLowerCase());
  if (genres.length) return genres.slice(0, MAX_TAGS);
  return (entity?.tags ?? [])
    .filter((t: any) => (t.count ?? 0) > 0)
    .sort((a: any, b: any) => (b.count ?? 0) - (a.count ?? 0))
    .map((t: any) => String(t.name).toLowerCase())
    .slice(0, MAX_TAGS);
}

async function lookupRecording(isrc: string) {
  const body = await mbGet(`/isrc/${encodeURIComponent(isrc)}?inc=artist-credits+tags&fmt=json`);
  const recordings: any[] = body?.recordings ?? [];
  // An ISRC can map to several recordings (duplicates); take the first credited one
  const rec = recordings.find((r) => (r["artist-credit"] ?? []).length) ?? recordings[0];
  if (!rec) return null;
  return {
    mbid: rec.id,
    artist_mbids: (rec["artist-credit"] ?? []).map((c: any) => c.artist?.id).filter(Boolean),
    tags: pickTags(rec),
  };
}

async function lookupArtist(mbid: string) {
  const body = await mbGet(`/artist/${encodeURIComponent(mbid)}?inc=tags+genres+artist-rels&fmt=json`);
  if (!body) return null;
  const related = (body.relations ?? [])
    .filter((r: any) => r["target-type"] === "artist" && RELATED_TYPES.has(r.type) && r.artist?.id)
    .map((r: any) => r.artist.id);
  return { name: body.name ?? null, tags: pickTags(body), related_mbids: [...new Set(related)].slice(0, MAX_RELATED) };
}

async function run() {
  const { data: got, error } = await admin.rpc("mb_enrich_begin", { p_seconds: Math.ceil(RUN_BUDGET_MS / 1000) + 10 });
  if (error) throw error;
  if (!got) return { skipped: "already_running" };

  const started = Date.now();
  let done = 0;
  let failed = 0;
  let lastError: string | null = null;
  try {
    while (Date.now() - started < RUN_BUDGET_MS) {
      const { data: work, error: workError } = await admin.rpc("mb_next_work");
      if (workError) throw workError;
      if (!work) break;
      try {
        if (work.kind === "recording") {
          const result = await lookupRecording(work.key);
          const { error: e } = await admin.rpc("mb_save_recording", { p_isrc: work.key, p_result: result });
          if (e) throw e;
        } else {
          const result = await lookupArtist(work.key);
          const { error: e } = await admin.rpc("mb_save_artist", { p_mbid: work.key, p_result: result });
          if (e) throw e;
        }
        done++;
      } catch (err) {
        failed++;
        lastError = err instanceof Error ? err.message : JSON.stringify(err);
        await admin.rpc("mb_fail", { p_kind: work.kind, p_key: work.key });
        console.error("[musicbrainz-enrich]", work.kind, work.key, err);
        // Back off for the rest of this run when MusicBrainz says so
        if (err instanceof RateLimited) break;
      }
    }
  } finally {
    await admin.rpc("mb_enrich_end");
  }
  return { done, failed, last_error: lastError };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 });
  const secret = Deno.env.get("SPOTIFY_WATCH_SECRET");
  if (!secret || req.headers.get("x-watch-secret") !== secret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }
  try {
    return new Response(JSON.stringify(await run()), { headers: { "Content-Type": "application/json" } });
  } catch (err) {
    console.error("[musicbrainz-enrich]", err);
    return new Response(JSON.stringify({ error: "internal_error" }), { status: 500 });
  }
});
