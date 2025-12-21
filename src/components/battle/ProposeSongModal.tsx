import { useState } from "react";
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

interface ProposeSongModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

// Placeholder song data for UI demonstration
const placeholderSongs = [
  { id: '1', title: 'Song Title One', artist: 'Artist A' },
  { id: '2', title: 'Song Title Two', artist: 'Artist B' },
  { id: '3', title: 'Song Title Three', artist: 'Artist C' },
  { id: '4', title: 'Song Title Four', artist: 'Artist D' },
  { id: '5', title: 'Song Title Five', artist: 'Artist E' },
];

const ProposeSongModal = ({ open, onOpenChange }: ProposeSongModalProps) => {
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedSongId, setSelectedSongId] = useState<string | null>(null);

  // Show placeholder results only when there's a search query
  const showResults = searchQuery.length > 0;

  const handleSelect = (songId: string) => {
    setSelectedSongId(songId);
  };

  const handleSubmit = () => {
    if (selectedSongId) {
      // TODO: Send proposal to backend
      setSearchQuery("");
      setSelectedSongId(null);
      onOpenChange(false);
    }
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
                {placeholderSongs.map((song) => (
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
            disabled={!selectedSongId}
            className="w-full h-12 text-base font-semibold rounded-xl bg-primary hover:bg-primary/90 text-primary-foreground disabled:opacity-40"
          >
            Propose Song
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
};

export default ProposeSongModal;
