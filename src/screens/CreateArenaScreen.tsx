import { useEffect, useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { useNavigate } from "react-router-dom";
import BackButton from "@/components/nav/BackButton";
import { arenaPath } from "@/lib/arenaRoutes";
import { createArena, ARENA_MOODS, ArenaMood } from "@/integrations/supabase/arenas";
import {
  getMyPlaylists,
  getMyStreamingConnection,
  searchSpotifyTracks,
  SpotifyHostError,
  SpotifyPlaylist,
  SpotifyTrack,
  startSpotifyConnect,
  StreamingConnectionSummary,
} from "@/integrations/supabase/spotify";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";

const SEARCH_DEBOUNCE_MS = 350;

const MOOD_GROUPS = Array.from(new Set(ARENA_MOODS.map((m) => m.group)));

const CreateArenaScreen = () => {
  const navigate = useNavigate();
  const [arenaName, setArenaName] = useState("");
  const [mood, setMood] = useState<ArenaMood | null>(null);
  const [warmupQuery, setWarmupQuery] = useState("");
  const [warmupResults, setWarmupResults] = useState<SpotifyTrack[]>([]);
  const [warmupError, setWarmupError] = useState("");
  const [warmup, setWarmup] = useState<SpotifyTrack | null>(null);
  const [isCreating, setIsCreating] = useState(false);
  const [createError, setCreateError] = useState("");
  // Spotify belongs to the host, not the arena, and is required to create
  // one: the warm-up is a Spotify track (step 6)
  const [spotify, setSpotify] = useState<StreamingConnectionSummary | null>(null);
  const [spotifyLoaded, setSpotifyLoaded] = useState(false);
  const [spotifyError, setSpotifyError] = useState("");
  // Step 12b: where backup songs come from when nobody has proposed enough
  const [fallbackSource, setFallbackSource] = useState("liked");
  const [playlists, setPlaylists] = useState<SpotifyPlaylist[]>([]);
  const [needsReconnect, setNeedsReconnect] = useState(false);

  useEffect(() => {
    getMyStreamingConnection()
      .then(setSpotify)
      .catch(() => setSpotify(null))
      .finally(() => setSpotifyLoaded(true));
  }, []);

  useEffect(() => {
    if (!spotify) return;
    getMyPlaylists()
      .then(setPlaylists)
      .catch((err) => {
        setPlaylists([]);
        // Connection from before step 7: no library scopes
        setNeedsReconnect(err instanceof SpotifyHostError && err.code === "needs_reconnect");
      });
  }, [spotify]);

  const handleConnectSpotify = () => {
    setSpotifyError("");
    startSpotifyConnect("/create").catch((err) => setSpotifyError(err instanceof Error ? err.message : String(err)));
  };

  // Warm-up: free Spotify search with the host's own account (no mood
  // suggestions: Spotify has no recommendations for new apps)
  useEffect(() => {
    const query = warmupQuery.trim();
    setWarmupError("");
    if (!spotify || !query) {
      setWarmupResults([]);
      return;
    }

    let cancelled = false;
    const timeout = setTimeout(() => {
      searchSpotifyTracks(query)
        .then((rows) => {
          if (!cancelled) setWarmupResults(rows);
        })
        .catch((err) => {
          if (cancelled) return;
          setWarmupResults([]);
          setWarmupError(err instanceof Error ? err.message : String(err));
        });
    }, SEARCH_DEBOUNCE_MS);

    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [spotify, warmupQuery]);

  const handleCreateArena = async () => {
    if (!mood || !warmup) return;
    setIsCreating(true);
    try {
      setCreateError("");
      const result = await createArena(arenaName, mood, warmup.spotify_track_id, fallbackSource);
      console.log('Arena created:', result);
      // replace: browser back must not land on the filled form (duplicate arena)
      navigate(arenaPath(result.arena_code, "lobby"), { replace: true });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('Failed to create arena:', message, error);
      setCreateError(message);
      setIsCreating(false);
    }
  };

  return (
    <div className="relative min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center px-6 pt-20 pb-12">
      <BackButton onClick={() => navigate("/")} />
      <div className="w-full max-w-md flex flex-col items-center gap-6">
        {/* Header */}
        <div className="text-center animate-fade-in-up">
          <h1 className="neon-heading text-2xl md:text-3xl mb-2">
            Create Arena
          </h1>
          <p className="text-text-secondary">
            Set up your Music Fighter session
          </p>
        </div>

        {/* Host's Spotify: required (the warm-up and the arena playlist live there) */}
        <div className="w-full flex items-center justify-between gap-3 text-sm">
          {!spotifyLoaded ? null : spotify ? (
            <p className="text-muted-foreground truncate">Spotify · {spotify.display_name}</p>
          ) : (
            <>
              <p className="text-muted-foreground">Connect your Spotify Premium account to create an arena</p>
              <Button variant="neon" size="sm" disabled={isCreating} onClick={handleConnectSpotify}>
                Connect Spotify
              </Button>
            </>
          )}
        </div>
        {spotifyError && <p className="w-full text-sm text-destructive">{spotifyError}</p>}

        {/* Arena Name Input */}
        <div 
          className="w-full neon-panel rounded-2xl p-4 animate-fade-in-up" 
          style={{ animationDelay: "50ms" }}
        >
          <p className="neon-label mb-2">1 · Name</p>
          <Input
            type="text"
            placeholder="Arena name (optional)"
            value={arenaName}
            onChange={(e) => setArenaName(e.target.value)}
            disabled={isCreating}
            className="w-full h-12 text-center text-lg bg-secondary/80 border-border focus-visible:ring-song-a"
          />
        </div>

        {/* Mood - required, fixed for the arena's lifetime */}
        <div
          className="w-full neon-panel rounded-2xl p-4 animate-fade-in-up"
          style={{ animationDelay: "75ms" }}
        >
          <p className="neon-label mb-3">2 · Pick the mood</p>
          <div className="max-h-72 overflow-y-auto pr-1 space-y-4">
            {MOOD_GROUPS.map((group) => (
              <div key={group}>
                <p className="text-[11px] uppercase tracking-widest text-muted-foreground mb-2">
                  {group}
                </p>
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {ARENA_MOODS.filter((m) => m.group === group).map((m) => (
                    <button
                      key={m.value}
                      type="button"
                      onClick={() => setMood(m.value)}
                      disabled={isCreating}
                      aria-pressed={mood === m.value}
                      className={`h-11 rounded-lg text-sm font-medium transition-all ${
                        mood === m.value
                          ? "neon-row-selected text-foreground"
                          : "neon-row text-text-secondary hover:border-song-a/60"
                      }`}
                    >
                      {m.emoji} {m.label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Warm-up song - required, from Spotify; silent until Start Battles, then
            it is the playlist's first track and sets battle 1's duration */}
        {mood && (
          <div
            className="w-full neon-panel rounded-2xl p-4 animate-fade-in-up"
            style={{ animationDelay: "90ms" }}
          >
            <p className="neon-label mb-1">3 · Pick the warm-up song</p>
            <p className="text-xs text-muted-foreground mb-3">
              First track of the arena's Spotify playlist: it plays on your device when you start battles and lasts the whole first battle
            </p>
            <Input
              type="text"
              placeholder={spotify ? "Search Spotify" : "Connect Spotify to search"}
              value={warmupQuery}
              onChange={(e) => setWarmupQuery(e.target.value)}
              disabled={isCreating || !spotify}
              className="w-full h-10 mb-2 bg-secondary/80 border-border focus-visible:ring-song-a"
            />
            {warmup && (
              <div className="mb-3 rounded-xl border border-primary/30 bg-primary/5 p-2 space-y-2">
                <p className="flex items-center gap-1.5 px-1 text-[11px] font-semibold uppercase tracking-widest text-primary">
                  <span className="w-1.5 h-1.5 rounded-full bg-primary shadow-[0_0_6px_hsl(var(--primary))]" />
                  Warm-up selected
                </p>
                <SpotifyTrackRow track={warmup} selected />
              </div>
            )}
            {warmupResults.length > 0 && (
              <p className="px-1 mb-2 text-[11px] uppercase tracking-widest text-muted-foreground">
                Results · tap to pick
              </p>
            )}
            <div className="max-h-72 overflow-y-auto overflow-x-hidden pr-1 space-y-2">
              {warmupResults.map((track) => (
                <SpotifyTrackRow
                  key={track.spotify_track_id}
                  track={track}
                  selected={warmup?.spotify_track_id === track.spotify_track_id}
                  onSelect={() => setWarmup(track)}
                  disabled={isCreating}
                  unavailableLabel="Not available in your Spotify country"
                />
              ))}
              {warmupError && (
                <p className="text-sm text-destructive text-center py-2 rounded-xl border border-destructive/30 bg-destructive/5">
                  {warmupError}
                </p>
              )}
              {spotify && warmupQuery.trim() && warmupResults.length === 0 && !warmupError && (
                <p className="text-sm text-muted-foreground text-center py-4 neon-row rounded-xl">No songs found</p>
              )}
            </div>
          </div>
        )}

        {/* Backup music (step 12b): only the host's own library */}
        {spotify && (
          <div className="w-full neon-panel rounded-2xl p-4 animate-fade-in-up">
            <p className="neon-label mb-1">4 · Backup music</p>
            <p className="text-xs text-muted-foreground mb-3">
              When nobody has proposed enough songs, battles take songs from here and from the artists already playing
            </p>
            {needsReconnect ? (
              <p className="text-xs text-muted-foreground">
                Reconnect Spotify in Profile to choose a playlist; your Liked Songs will be tried
              </p>
            ) : (
              <select
                value={fallbackSource}
                onChange={(e) => setFallbackSource(e.target.value)}
                disabled={isCreating}
                className="w-full h-10 px-3 rounded-md bg-secondary/80 border border-border text-sm text-foreground"
              >
                {(playlists.length ? playlists : [{ id: "liked", name: "Liked Songs", total: 0 } as SpotifyPlaylist]).map(
                  (p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                      {p.total ? ` (${p.total})` : ""}
                    </option>
                  ),
                )}
              </select>
            )}
          </div>
        )}

        {/* Create Arena Button */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "100ms" }}
        >
          <Button
            onClick={handleCreateArena}
            disabled={isCreating || !mood || !warmup || !spotify}
            className="w-full h-12 text-lg font-bold"
          >
            {isCreating ? "Creating..." : "Create Arena"}
          </Button>
          {createError && <p className="mt-2 text-sm text-destructive">{createError}</p>}
        </div>
      </div>
    </div>
  );
};

export default CreateArenaScreen;
