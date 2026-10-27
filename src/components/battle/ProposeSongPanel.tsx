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
  SongResult,
} from "@/integrations/supabase/proposals";

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
  const [results, setResults] = useState<SongResult[]>([]);
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
    searchSongs(arenaId, searchQuery)
      .then((rows) => {
        if (!cancelled) setResults(rows);
      })
      .catch(() => {
        if (!cancelled) setResults([]);
      });

    return () => {
      cancelled = true;
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
    } catch {
      setNotice("Couldn't propose the song");
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="h-full flex flex-col gap-4">
      {/* Search Input */}
      <div className="relative flex-shrink-0">
        <Search className="absolute left-4 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
        <Input
          placeholder="Search for a song..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="pl-11 h-12 bg-secondary/50 border-border/50 text-foreground placeholder:text-muted-foreground rounded-xl focus:ring-primary"
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
              <div className="w-20 h-20 rounded-full bg-secondary/50 flex items-center justify-center mb-5">
                <Music className="h-10 w-10 text-muted-foreground" />
              </div>
              <p className="text-muted-foreground text-sm">You haven't proposed any song yet</p>
            </div>
          ) : (
            // My proposals still waiting in the queue
            <ScrollArea className="h-full">
              <p className="text-xs text-muted-foreground mb-2">Your proposals in the queue</p>
              <div className="space-y-2 pr-4">
                {myProposals.map((proposal) => (
                  <div key={proposal.queue_id} className="p-3 rounded-xl bg-secondary/50">
                    <p className="text-sm font-medium text-foreground truncate">{proposal.title}</p>
                    <p className="text-muted-foreground text-xs truncate">{proposal.artist}</p>
                  </div>
                ))}
              </div>
            </ScrollArea>
          )
        ) : (
          // Search results
          <ScrollArea className="h-full">
            <div className="space-y-2 pr-4">
              {results.map((song) => (
                <div
                  key={song.id}
                  onClick={() => setSelectedSongId(song.id)}
                  className={`
                    p-3 rounded-xl cursor-pointer transition-all duration-200
                    ${selectedSongId === song.id
                      ? 'bg-primary/15 ring-1 ring-primary'
                      : 'bg-secondary/50 hover:bg-secondary/80'
                    }
                  `}
                  role="button"
                  aria-pressed={selectedSongId === song.id}
                >
                  <div className="flex items-center gap-3">
                    <div className="w-12 h-12 rounded-lg bg-muted/50 flex items-center justify-center flex-shrink-0">
                      <Music className={`h-5 w-5 ${selectedSongId === song.id ? 'text-primary' : 'text-muted-foreground'}`} />
                    </div>
                    <div className="min-w-0">
                      <p className={`text-sm font-medium truncate ${selectedSongId === song.id ? 'text-primary' : 'text-foreground'}`}>
                        {song.title}
                      </p>
                      <p className="text-muted-foreground text-xs truncate">
                        {song.artist}
                      </p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </ScrollArea>
        )}
      </div>

      {notice && <p className="flex-shrink-0 text-sm text-center text-muted-foreground">{notice}</p>}

      {/* Submit Button */}
      <div className="flex-shrink-0 pt-2">
        <Button
          onClick={handleSubmit}
          disabled={!selectedSongId || isSubmitting}
          className="w-full h-12 text-base font-semibold rounded-xl bg-primary hover:bg-primary/90 text-primary-foreground disabled:opacity-40"
        >
          {isSubmitting ? "Proposing..." : "Propose Song"}
        </Button>
      </div>
    </div>
  );
};

export default ProposeSongPanel;
