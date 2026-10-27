import { useEffect, useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { useNavigate } from "react-router-dom";
import BackButton from "@/components/nav/BackButton";
import { arenaPath } from "@/lib/arenaRoutes";
import {
  createArena,
  formatDuration,
  getWarmupSuggestions,
  ARENA_MOODS,
  ArenaMood,
  WarmupSuggestion,
} from "@/integrations/supabase/arenas";
import {
  getMyStreamingConnection,
  startSpotifyConnect,
  StreamingConnectionSummary,
} from "@/integrations/supabase/spotify";

const MOOD_GROUPS = Array.from(new Set(ARENA_MOODS.map((m) => m.group)));

const CreateArenaScreen = () => {
  const navigate = useNavigate();
  const [arenaName, setArenaName] = useState("");
  const [mood, setMood] = useState<ArenaMood | null>(null);
  const [warmupQuery, setWarmupQuery] = useState("");
  const [warmupSuggestions, setWarmupSuggestions] = useState<WarmupSuggestion[]>([]);
  const [warmup, setWarmup] = useState<WarmupSuggestion | null>(null);
  const [isCreating, setIsCreating] = useState(false);
  // Spotify belongs to the host, not the arena: it can be connected before
  // creating one (it will be needed when the warm-up comes from Spotify, step 6)
  const [spotify, setSpotify] = useState<StreamingConnectionSummary | null>(null);
  const [spotifyError, setSpotifyError] = useState("");

  useEffect(() => {
    getMyStreamingConnection()
      .then(setSpotify)
      .catch(() => setSpotify(null));
  }, []);

  const handleConnectSpotify = () => {
    setSpotifyError("");
    startSpotifyConnect("/create").catch((err) => setSpotifyError(err instanceof Error ? err.message : String(err)));
  };

  // Warm-up suggestions follow the chosen mood (MVP: curated library only)
  useEffect(() => {
    if (!mood) {
      setWarmupSuggestions([]);
      return;
    }

    let cancelled = false;
    getWarmupSuggestions(mood, warmupQuery)
      .then((rows) => {
        if (!cancelled) setWarmupSuggestions(rows);
      })
      .catch(() => {
        if (!cancelled) setWarmupSuggestions([]);
      });

    return () => {
      cancelled = true;
    };
  }, [mood, warmupQuery]);

  const handleCreateArena = async () => {
    if (!mood || !warmup) return;
    setIsCreating(true);
    try {
      const result = await createArena(arenaName, mood, warmup.id);
      console.log('Arena created:', result);
      // replace: browser back must not land on the filled form (duplicate arena)
      navigate(arenaPath(result.arena_code, "lobby"), { replace: true });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('Failed to create arena:', message, error);
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

        {/* Host's Spotify (optional until step 6) */}
        <div className="w-full flex items-center justify-between gap-3 text-sm">
          {spotify ? (
            <p className="text-muted-foreground truncate">Spotify · {spotify.display_name}</p>
          ) : (
            <>
              <p className="text-muted-foreground">Spotify not connected</p>
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

        {/* Warm-up song - required; silent until Start Battles, then it is the
            first song of the session and sets battle 1's duration */}
        {mood && (
          <div
            className="w-full neon-panel rounded-2xl p-4 animate-fade-in-up"
            style={{ animationDelay: "90ms" }}
          >
            <p className="neon-label mb-1">3 · Pick the warm-up song</p>
            <p className="text-xs text-muted-foreground mb-3">
              It starts playing when you start battles and lasts the whole first battle
            </p>
            <Input
              type="text"
              placeholder="Search songs or artists"
              value={warmupQuery}
              onChange={(e) => setWarmupQuery(e.target.value)}
              disabled={isCreating}
              className="w-full h-10 mb-2 bg-secondary/80 border-border focus-visible:ring-song-a"
            />
            <div className="max-h-60 overflow-y-auto pr-1 space-y-1">
              {warmupSuggestions.map((song) => (
                <button
                  key={song.id}
                  type="button"
                  onClick={() => setWarmup(song)}
                  disabled={isCreating}
                  aria-pressed={warmup?.id === song.id}
                  className={`w-full flex items-center gap-3 px-3 py-2 rounded-lg text-left transition-all ${
                    warmup?.id === song.id
                      ? "neon-row-selected"
                      : "neon-row hover:border-song-a/60"
                  }`}
                >
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-foreground truncate">{song.title}</p>
                    <p className="text-xs text-muted-foreground truncate">{song.artist}</p>
                  </div>
                  {song.matches_mood && (
                    <span className="flex-shrink-0 px-2 py-0.5 rounded-full border border-song-a/50 text-[10px] text-song-a">
                      Fits mood
                    </span>
                  )}
                  <span className="flex-shrink-0 text-xs text-muted-foreground tabular-nums">
                    {formatDuration(song.duration_ms)}
                  </span>
                </button>
              ))}
              {warmupSuggestions.length === 0 && (
                <p className="text-sm text-muted-foreground text-center py-4">No songs found</p>
              )}
            </div>
          </div>
        )}

        {/* Create Arena Button */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "100ms" }}
        >
          <Button
            onClick={handleCreateArena}
            disabled={isCreating || !mood || !warmup}
            className="w-full h-12 text-lg font-bold"
          >
            {isCreating ? "Creating..." : "Create Arena"}
          </Button>
        </div>
      </div>
    </div>
  );
};

export default CreateArenaScreen;
