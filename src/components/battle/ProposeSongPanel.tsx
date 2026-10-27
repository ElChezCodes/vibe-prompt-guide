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
import {
  CatalogAccount,
  getProposeSources,
  ProposeSources,
  SpotifyHostError,
  SpotifyTrack,
} from "@/integrations/supabase/spotify";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import MyPlaylistsBrowser from "@/components/streaming/MyPlaylistsBrowser";

const SEARCH_DEBOUNCE_MS = 350;

interface ProposeSongPanelProps {
  arenaId: string;
  onProposed?: () => void;
}

// Shared by the Battle Room modal and the Proponer screen. Both mount it
// fresh and load "my proposals" from the backend, so each reflects what was
// done in the other. Step 7: a member with their own Spotify connected can
// also search with it (falling back to the host's) and pick from their own
// playlists; every proposal still goes through the same spotify-host propose.
const ProposeSongPanel = ({ arenaId, onProposed }: ProposeSongPanelProps) => {
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedSongId, setSelectedSongId] = useState<string | null>(null);
  // Which account the selected song was found with (propose re-reads it with that one)
  const [selectedAccount, setSelectedAccount] = useState<CatalogAccount>("own");
  const [results, setResults] = useState<SpotifyTrack[]>([]);
  const [sources, setSources] = useState<ProposeSources | null>(null);
  const [tab, setTab] = useState<"search" | "playlists">("search");
  const [searchAccount, setSearchAccount] = useState<CatalogAccount>("own");
  const [searchedWith, setSearchedWith] = useState<CatalogAccount | null>(null);
  const [myProposals, setMyProposals] = useState<MyProposal[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [notice, setNotice] = useState("");

  const showResults = tab === "search" && searchQuery.length > 0;
  // The host's own account is the host's: nothing to choose
  const canChooseAccount = !!sources?.own_connected && !sources.is_host;

  useEffect(() => {
    getProposeSources(arenaId)
      .then(setSources)
      .catch(() => setSources(null));
  }, [arenaId]);

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
      searchSongs(arenaId, searchQuery, searchAccount)
        .then(({ tracks, account }) => {
          if (cancelled) return;
          setResults(tracks);
          setSearchedWith(account);
        })
        .catch((err) => {
          if (cancelled) return;
          setResults([]);
          if (err instanceof SpotifyHostError && err.code === "host_spotify_unavailable") {
            setNotice("Search is unavailable: the host's Spotify isn't connected");
          } else {
            setNotice(err instanceof Error ? err.message : String(err));
          }
        });
    }, SEARCH_DEBOUNCE_MS);

    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [searchQuery, showResults, arenaId, searchAccount]);

  const handleSubmit = async () => {
    if (!selectedSongId || isSubmitting) return;

    setIsSubmitting(true);
    setNotice("");
    try {
      const result = await proposeSong(arenaId, selectedSongId, selectedAccount);
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

  const selectTrack = (trackId: string, account: CatalogAccount) => {
    setSelectedSongId(trackId);
    setSelectedAccount(account);
  };

  const switchTab = (next: "search" | "playlists") => {
    setTab(next);
    setSelectedSongId(null);
    setNotice("");
  };

  return (
    <div className="h-full flex flex-col gap-4">
      {/* Sources: their own playlists only with their own Spotify connected */}
      {sources?.own_connected && (
        <div className="flex-shrink-0 grid grid-cols-2 gap-2">
          <Button variant={tab === "search" ? "default" : "ghost"} onClick={() => switchTab("search")}>
            Search
          </Button>
          <Button variant={tab === "playlists" ? "default" : "ghost"} onClick={() => switchTab("playlists")}>
            My playlists
          </Button>
        </div>
      )}

      {tab === "playlists" ? (
        <div className="flex-1 min-h-0">
          <MyPlaylistsBrowser
            arenaId={arenaId}
            needsReconnect={!sources?.can_read_library}
            selectedTrackId={selectedSongId}
            onSelect={(track) => selectTrack(track.spotify_track_id, "own")}
          />
        </div>
      ) : (
      <>
      {canChooseAccount && (
        <div className="flex-shrink-0 flex items-center justify-between gap-2 text-xs text-text-secondary">
          <span>Search with</span>
          <div className="flex gap-1">
            {(["own", "host"] as const).map((account) => (
              <Button
                key={account}
                size="sm"
                variant={searchAccount === account ? "default" : "ghost"}
                onClick={() => setSearchAccount(account)}
              >
                {account === "own" ? "My Spotify" : "Host's Spotify"}
              </Button>
            ))}
          </div>
        </div>
      )}

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
              {/* Their own account failed (or was revoked): the host's answered */}
              {canChooseAccount && searchAccount === "own" && searchedWith === "host" && (
                <p className="text-xs text-muted-foreground">Searched with the host's Spotify</p>
              )}
              {results.map((track) => (
                <SpotifyTrackRow
                  key={track.spotify_track_id}
                  track={track}
                  selected={selectedSongId === track.spotify_track_id}
                  onSelect={() => selectTrack(track.spotify_track_id, searchedWith ?? searchAccount)}
                />
              ))}
            </div>
          </ScrollArea>
        )}
      </div>
      </>
      )}

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
