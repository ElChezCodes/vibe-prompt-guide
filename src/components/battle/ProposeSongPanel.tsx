import { useCallback, useEffect, useState } from "react";
import { Search, Music, X } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  getMyProposals,
  MyProposal,
  proposeSong,
  searchSongs,
} from "@/integrations/supabase/proposals";
import { SpotifyHostError, SpotifyTrack } from "@/integrations/supabase/spotify";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";

const SEARCH_DEBOUNCE_MS = 350;

interface ProposeSongPanelProps {
  arenaId: string;
  onProposed?: () => void;
}

// Shared by the Battle Room modal and the Proponer screen. Both mount it
// fresh and load "my proposals" from the backend, so each reflects what was
// done in the other.
const ProposeSongPanel = ({ arenaId, onProposed }: ProposeSongPanelProps) => {
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedSongId, setSelectedSongId] = useState<string | null>(null);
  const [results, setResults] = useState<SpotifyTrack[]>([]);
  const [myProposals, setMyProposals] = useState<MyProposal[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [notice, setNotice] = useState("");

  const showResults = searchQuery.length > 0;

  const loadMyProposals = useCallback(() => {
    getMyProposals(arenaId)
      .then(setMyProposals)
      .catch(() => setMyProposals([]));
  }, [arenaId]);

  useEffect(() => {
    loadMyProposals();
  }, [loadMyProposals]);

  useEffect(() => {
    if (!showResults) {
      setResults([]);
      return;
    }

    let cancelled = false;
    const timeout = setTimeout(() => {
      searchSongs(arenaId, searchQuery)
        .then((rows) => {
          if (!cancelled) setResults(rows);
        })
        .catch((err) => {
          if (cancelled) return;
          setResults([]);
          if (err instanceof SpotifyHostError && err.code === "host_spotify_unavailable") {
            setNotice("Search is unavailable: the host's Spotify isn't connected");
          }
        });
    }, SEARCH_DEBOUNCE_MS);

    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [searchQuery, showResults, arenaId]);

  const handleSubmit = async () => {
    if (!selectedSongId || isSubmitting) return;

    setIsSubmitting(true);
    setNotice("");
    try {
      const result = await proposeSong(arenaId, selectedSongId);
      setNotice(result === "already_queued" ? "That song is already in the queue" : "Song proposed");
      setSearchQuery("");
      setSelectedSongId(null);
      loadMyProposals();
      if (result === "proposed") onProposed?.();
    } catch (err) {
      setNotice(
        err instanceof SpotifyHostError && err.code === "host_spotify_unavailable"
          ? "Can't propose now: the host's Spotify isn't connected"
          : "Couldn't propose the song",
      );
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="h-full flex flex-col gap-4">
      {/* Search Input */}
      <div className="relative flex-shrink-0">
        <Search className="absolute left-4 top-1/2 -translate-y-1/2 h-4 w-4 text-song-a" />
        <Input
          placeholder="Search Spotify..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="pl-11 h-12 bg-secondary/80 border-song-a/40 text-foreground placeholder:text-muted-foreground rounded-xl focus-visible:ring-song-a"
        />
        {searchQuery && (
          <button
            onClick={() => setSearchQuery("")}
            className="absolute right-4 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground transition-colors"
          >
            <X className="h-4 w-4" />
          </button>
        )}
      </div>

      {/* Results Area */}
      <div className="flex-1 min-h-0">
        {!showResults ? (
          myProposals.length === 0 ? (
            // Empty state
            <div className="h-full flex flex-col items-center justify-center text-center px-6">
              <div className="w-20 h-20 rounded-full neon-outline flex items-center justify-center mb-5">
                <Music className="h-9 w-9 text-song-b icon-glow-b" />
              </div>
              <p className="text-text-secondary text-sm">You haven't proposed any song yet</p>
              <p className="mt-1 text-muted-foreground text-xs">Search above to send one into the queue</p>
            </div>
          ) : (
            // My proposals still waiting in the queue
            <ScrollArea className="h-full">
              <p className="neon-label mb-3">Your proposals in the queue</p>
              <div className="space-y-2 pr-4">
                {myProposals.map((proposal) => (
                  <div key={proposal.queue_id} className="flex items-center gap-3 p-3 rounded-xl neon-row">
                    <div className="w-9 h-9 rounded-lg bg-song-a/10 flex items-center justify-center flex-shrink-0">
                      <Music className="h-4 w-4 text-song-a" />
                    </div>
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-foreground truncate">{proposal.title}</p>
                      <p className="text-muted-foreground text-xs truncate">{proposal.artist}</p>
                    </div>
                  </div>
                ))}
              </div>
            </ScrollArea>
          )
        ) : (
          // Search results
          <ScrollArea className="h-full">
            <div className="space-y-2 pr-4">
              {results.map((track) => (
                <SpotifyTrackRow
                  key={track.spotify_track_id}
                  track={track}
                  selected={selectedSongId === track.spotify_track_id}
                  onSelect={() => setSelectedSongId(track.spotify_track_id)}
                />
              ))}
            </div>
          </ScrollArea>
        )}
      </div>

      {notice && <p className="flex-shrink-0 text-sm text-center text-song-a">{notice}</p>}

      {/* Submit Button */}
      <div className="flex-shrink-0 pt-2">
        <Button
          onClick={handleSubmit}
          disabled={!selectedSongId || isSubmitting}
          className="w-full h-12 text-base font-bold rounded-xl disabled:opacity-40"
        >
          {isSubmitting ? "Proposing..." : "Propose Song"}
        </Button>
      </div>
    </div>
  );
};

export default ProposeSongPanel;
