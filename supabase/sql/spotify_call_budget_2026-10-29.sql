-- ===========================================================================
-- Spotify call budget (2026-10-29). Found in-app: Spotify answered 429 "Too
-- many requests, retry in 14.3 h" after an arena ran ~6 h (00:07-06:07 UTC,
-- 1040 watch checks). Every 15 s the watcher did 2 player calls, plus a full
-- reserve refill whenever the reserve wasn't full (2 library reads per lender
-- and up to 2 artist searches, every tick when nothing new could be added),
-- plus uncached track lookups for relinked/unknown/unplayable tracks.
--
-- spotify-host now (same commit):
--   * stops all background Spotify work (watch, nudge, reserve refill) while
--     Spotify's Retry-After runs (spotify_rate_limit, recorded on any 429),
--     so a ban isn't prolonged;
--   * refills an arena's reserve at most every minute, every 10 minutes when
--     a refill added nothing (arena_playback.reserve_refill_after);
--   * reads the player once per check (the device list only when nothing is
--     playing) and remembers track lookups that found nothing.
-- ===========================================================================

-- When Spotify lets the app call again (one row, service-only)
create table if not exists public.spotify_rate_limit (
  id boolean primary key default true check (id),
  until timestamptz not null,
  updated_at timestamptz not null default now()
);
alter table public.spotify_rate_limit enable row level security;
revoke all on public.spotify_rate_limit from anon, authenticated;

-- Next time the watcher may refill this arena's reserve from Spotify
alter table public.arena_playback add column if not exists reserve_refill_after timestamptz;
