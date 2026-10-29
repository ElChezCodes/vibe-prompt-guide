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
 *
 * Step 17 (matchmaking, supabase/sql/matchmaking_2026-10-29.sql) adds, once
 * per song: MusicBrainz's genre list (monthly), a search by title + first
 * artist when the ISRC isn't in MusicBrainz (only MBIDs are kept), and
 * ListenBrainz open data by MBID (no key, CC0): recording/release-group tags
 * (kept only when they are MusicBrainz genres) and similar artists from
 * listening sessions. ListenBrainz allows ~30 requests / 10 s.
 */

const MB = "https://musicbrainz.org/ws/2";
const LB_LABS = "https://labs.api.listenbrainz.org";
// ListenBrainz's documented session-based similar-artists dataset
const LB_SIMILAR_ALGORITHM = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30";
const LB_REQUEST_GAP_MS = 400;
const MAX_SIMILAR = 20;
// Accept a search hit only this sure (MusicBrainz score 0-100)
const SEARCH_MIN_SCORE = 90;
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
let lastLbRequestAt = 0;

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

async function lbGet(url: string): Promise<any | null> {
  const wait = lastLbRequestAt + LB_REQUEST_GAP_MS - Date.now();
  if (wait > 0) await sleep(wait);
  lastLbRequestAt = Date.now();
  const res = await fetch(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  if (res.status === 404) return null;
  if (res.status === 503 || res.status === 429) throw new RateLimited(`ListenBrainz ${res.status}`);
  if (!res.ok) throw new Error(`ListenBrainz ${res.status}`);
  return await res.json();
}

async function loadGenres(): Promise<string[]> {
  const wait = lastRequestAt + REQUEST_GAP_MS - Date.now();
  if (wait > 0) await sleep(wait);
  lastRequestAt = Date.now();
  const res = await fetch(`${MB}/genre/all?fmt=txt`, { headers: { "User-Agent": USER_AGENT } });
  if (res.status === 503 || res.status === 429) throw new RateLimited(`MusicBrainz ${res.status}`);
  if (!res.ok) throw new Error(`MusicBrainz ${res.status}`);
  return (await res.text()).split("\n").map((g) => g.trim().toLowerCase()).filter(Boolean);
}

// Lowercase, no accents, letters/digits only: "Beyoncé" == "beyonce"
const norm = (s: string) =>
  s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");

// Spotify-style suffixes that aren't part of the recording's title
const cleanTitle = (t: string) =>
  t.replace(/\s+-\s+.*$/, "").replace(/\s*[([](feat|ft|with)\.?\s[^)\]]*[)\]]/gi, "").trim() || t;

// Lucene phrase: only quotes and backslashes need escaping
const phrase = (s: string) => `"${s.replace(/[\\"]/g, "\\$&")}"`;

// ISRC not in MusicBrainz: the recording by title + artist, else the artist
async function searchRecording(title: string, artist: string) {
  const want = norm(artist);
  if (!want) return null;
  const q = `recording:${phrase(cleanTitle(title))} AND artist:${phrase(artist)}`;
  const body = await mbGet(`/recording?query=${encodeURIComponent(q)}&limit=5&fmt=json`);
  const rec = (body?.recordings ?? []).find(
    (r: any) =>
      (r.score ?? 0) >= SEARCH_MIN_SCORE &&
      (r["artist-credit"] ?? []).some((c: any) => norm(c.name ?? c.artist?.name ?? "") === want),
  );
  if (rec) {
    return {
      mbid: rec.id,
      artist_mbids: (rec["artist-credit"] ?? []).map((c: any) => c.artist?.id).filter(Boolean),
      tags: pickTags(rec),
      source: "search_recording",
    };
  }
  const artists = await mbGet(`/artist?query=${encodeURIComponent(`artist:${phrase(artist)}`)}&limit=5&fmt=json`);
  const hit = (artists?.artists ?? []).find((a: any) => (a.score ?? 0) >= SEARCH_MIN_SCORE && norm(a.name ?? "") === want);
  if (!hit) return null;
  return { mbid: null, artist_mbids: [hit.id], tags: [], source: "search_artist" };
}

async function lbTags(recordingMbid: string): Promise<string[]> {
  const rows: any[] =
    (await lbGet(`${LB_LABS}/bulk-tag-lookup/json?recording_mbid=${encodeURIComponent(recordingMbid)}`)) ?? [];
  return [...new Set(rows.map((r) => String(r.tag ?? "").toLowerCase()).filter(Boolean))];
}

async function lbSimilar(artistMbid: string): Promise<string[]> {
  const rows: any[] =
    (await lbGet(
      `${LB_LABS}/similar-artists/json?artist_mbids=${encodeURIComponent(artistMbid)}&algorithm=${LB_SIMILAR_ALGORITHM}`,
    )) ?? [];
  return rows
    .filter((r) => r.artist_mbid && r.artist_mbid !== artistMbid)
    .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
    .slice(0, MAX_SIMILAR)
    .map((r) => r.artist_mbid);
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
  // MusicBrainz said 503/429: ListenBrainz work only for the rest of the run
  let lbOnly = false;
  try {
    while (Date.now() - started < RUN_BUDGET_MS) {
      const { data: work, error: workError } = await admin.rpc("mb_next_work", { p_lb_only: lbOnly });
      if (workError) throw workError;
      if (!work) break;
      try {
        if (work.kind === "recording") {
          const result = await lookupRecording(work.key);
          const { error: e } = await admin.rpc("mb_save_recording", { p_isrc: work.key, p_result: result });
          if (e) throw e;
        } else if (work.kind === "genres") {
          const { error: e } = await admin.rpc("mb_save_genres", { p_names: await loadGenres() });
          if (e) throw e;
        } else if (work.kind === "search") {
          const result = await searchRecording(work.title, work.artist);
          const { error: e } = await admin.rpc("mb_save_search", { p_isrc: work.key, p_result: result });
          if (e) throw e;
        } else if (work.kind === "lb_tags") {
          const { error: e } = await admin.rpc("mb_save_lb_tags", { p_isrc: work.key, p_tags: await lbTags(work.mbid) });
          if (e) throw e;
        } else if (work.kind === "lb_similar") {
          const { error: e } = await admin.rpc("mb_save_lb_similar", {
            p_mbid: work.key,
            p_similar: await lbSimilar(work.key),
          });
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
        console.error("[musicbrainz-enrich]", work.kind, work.key, err);
        // Rate limits aren't the song's fault: no attempt counted (mb_next_work
        // already put it 5 min back). MusicBrainz: ListenBrainz only for the
        // rest of the run; ListenBrainz: stop.
        if (err instanceof RateLimited) {
          if (lbOnly || work.kind === "lb_tags" || work.kind === "lb_similar") break;
          lbOnly = true;
          continue;
        }
        await admin.rpc("mb_fail", { p_kind: work.kind, p_key: work.key });
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
