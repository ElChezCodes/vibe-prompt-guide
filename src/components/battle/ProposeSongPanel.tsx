import { useCallback, useEffect, useState } from "react";
import { Search, Music, X } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useArenaQueueSummary } from "@/hooks/useArenaQueueSummary";
import {
  getMyProposals,
  LOW_QUEUE_THRESHOLD,
  MyProposal,
  ProposalStatus,
  proposeSong,
  searchSongs,
  withdrawProposal,
} from "@/integrations/supabase/proposals";
import {
  CatalogAccount,
  getProposeSources,
  ProposeOutcome,
  ProposeSources,
  SpotifyHostError,
  SpotifyTrack,
} from "@/integrations/supabase/spotify";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import MyPlaylistsBrowser from "@/components/streaming/MyPlaylistsBrowser";

const SEARCH_DEBOUNCE_MS = 350;

// Step 12 queue rules, decided by the backend (validate_queue_proposal)
const proposeNotice = ({ result, available_at }: ProposeOutcome): string => {
  switch (result) {
    case "proposed":
      return "Song proposed";
    case "already_queued":
      return "That song is already in the queue";
    case "in_battle":
      return "That song is fighting right now";
    case "is_warmup":
      return "That's the warm-up song";
    case "recently_played": {
      const at = available_at ? new Date(available_at) : null;
      return at
        ? `That song played recently: you can propose it again at ${at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`
        : "That song played recently: try again later";
    }
    case "proposer_queue_full":
      return "You already have 5 songs in the queue: wait until one fights";
    case "queue_full":
      return "The fighters list is full… please wait a few minutes";
  }
};

const statusLabel = (p: MyProposal): string => {
  const labels: Record<ProposalStatus, string> = {
    next: `#${p.place} in the next 10`,
    waiting: `Waiting #${p.place} · ${p.battles_left} battles before it's dropped`,
    competing: "Fighting now",
    won: "Won",
    lost: "Lost",
    draw: "Draw",
    cancelled: "Battle cancelled",
    purged: "Dropped after 20 battles waiting",
    withdrawn: "Withdrawn",
  };
  return labels[p.status];
};

interface ProposeSongPanelProps {
  arenaId: string;
}

// Shared by the Battle Room modal and the Proponer screen. Both mount it
// fresh and load "my proposals" from the backend, so each reflects what was
// done in the other. Step 7: a member with their own Spotify connected can
// also search with it (falling back to the host's) and pick from their own
// playlists; every proposal still goes through the same spotify-host propose.
const ProposeSongPanel = ({ arenaId }: ProposeSongPanelProps) => {
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

  const queueSummary = useArenaQueueSummary(arenaId);
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

  // Places and outcomes change with every battle (step 12)
  useEffect(() => {
    loadMyProposals();
    const interval = setInterval(loadMyProposals, 15000);
    return () => clearInterval(interval);
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
      const outcome = await proposeSong(arenaId, selectedSongId, selectedAccount);
      setNotice(proposeNotice(outcome));
      // The query and its results stay, so several songs of the same search
      // (e.g. one artist) can be proposed in a row (user request 2026-10-27)
      setSelectedSongId(null);
      loadMyProposals();
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

  const handleWithdraw = async (queueId: string) => {
    try {
      await withdrawProposal(queueId);
      setNotice("Proposal withdrawn");
    } catch {
      // It may have just entered a battle
      setNotice("Couldn't withdraw it");
    }
    loadMyProposals();
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
      {queueSummary && queueSummary.human_queued < LOW_QUEUE_THRESHOLD && (
        <p className="flex-shrink-0 text-xs text-center text-song-b">
          The queue is running low: propose a song!
        </p>
      )}
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
              <p className="neon-label mb-3">Your proposals</p>
              <div className="space-y-2 pr-4">
                {myProposals.map((proposal) => (
                  <div
                    key={proposal.queue_id ?? `${proposal.song_id}-${proposal.at}`}
                    className="flex items-center gap-3 p-3 rounded-xl neon-row"
                  >
                    <div className="w-9 h-9 rounded-lg bg-song-a/10 flex items-center justify-center flex-shrink-0">
                      <Music className="h-4 w-4 text-song-a" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium text-foreground truncate">{proposal.title}</p>
                      <p className="text-muted-foreground text-xs truncate">{proposal.artist}</p>
                      <p className="text-xs text-song-a truncate">{statusLabel(proposal)}</p>
                    </div>
                    {proposal.queue_id && (
                      <Button size="sm" variant="ghost" onClick={() => handleWithdraw(proposal.queue_id)}>
                        Withdraw
                      </Button>
                    )}
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
