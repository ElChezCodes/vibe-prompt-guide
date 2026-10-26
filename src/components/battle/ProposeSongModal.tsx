import { useEffect, useState } from "react";
import { Search, Music, X } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { supabase } from "@/integrations/supabase/client";

interface ProposeSongModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  arenaId: string;
}

interface SongResult {
  id: string;
  title: string;
  artist: string;
}

const ProposeSongModal = ({ open, onOpenChange, arenaId }: ProposeSongModalProps) => {
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedSongId, setSelectedSongId] = useState<string | null>(null);
  const [results, setResults] = useState<SongResult[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const showResults = searchQuery.length > 0;

  useEffect(() => {
    if (!showResults) {
      setResults([]);
      return;
    }

    let cancelled = false;
    const run = async () => {
      // Server-side: this arena's songs + the curated library (songs table
      // has no client SELECT policy by design)
      const { data, error } = await supabase.rpc("search_songs", {
        p_arena_id: arenaId,
        p_query: searchQuery,
      });

      if (cancelled) return;
      if (error) {
        console.error("[ProposeSongModal] song search failed:", error);
        setResults([]);
        return;
      }
      setResults(data ?? []);
    };

    run();
    return () => {
      cancelled = true;
    };
  }, [searchQuery, showResults, arenaId]);

  const handleSelect = (songId: string) => {
    setSelectedSongId(songId);
  };

  const handleSubmit = async () => {
    if (!selectedSongId || isSubmitting) return;

    setIsSubmitting(true);
    const { error } = await supabase.from("queues").insert({
      arena_id: arenaId,
      song_id: selectedSongId,
      queue_type: "waiting",
      position: 0,
      priority: 1,
    });

    if (error) {
      // Unique violation (queues_arena_song_unique) means it's already
      // queued -- treat as a harmless no-op, not a failure to surface.
      if (error.code !== "23505") {
        console.error("[ProposeSongModal] proposal insert failed:", error);
        setIsSubmitting(false);
        return;
      }
    }

    setIsSubmitting(false);
    setSearchQuery("");
    setSelectedSongId(null);
    onOpenChange(false);
  };

  const handleClose = () => {
    setSearchQuery("");
    setSelectedSongId(null);
    onOpenChange(false);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border/50 max-w-md mx-auto h-[80vh] flex flex-col gap-4">
        <DialogHeader className="flex-shrink-0">
          <DialogTitle className="text-foreground text-xl font-semibold">
            Propose a Song
          </DialogTitle>
        </DialogHeader>

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
            // Empty state
            <div className="h-full flex flex-col items-center justify-center text-center px-6">
              <div className="w-20 h-20 rounded-full bg-secondary/50 flex items-center justify-center mb-5">
                <Music className="h-10 w-10 text-muted-foreground" />
              </div>
              <p className="text-muted-foreground text-sm">
                Search for a song to propose
              </p>
            </div>
          ) : (
            // Search results
            <ScrollArea className="h-full">
              <div className="space-y-2 pr-4">
                {results.map((song) => (
                  <div
                    key={song.id}
                    onClick={() => handleSelect(song.id)}
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
      </DialogContent>
    </Dialog>
  );
};

export default ProposeSongModal;
