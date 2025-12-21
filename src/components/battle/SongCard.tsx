import { Music } from "lucide-react";

interface SongCardProps {
  position: 'left' | 'right';
  songTitle?: string;
  artistName?: string;
  isSelected?: boolean;
  isDisabled?: boolean;
  onVote?: () => void;
}

const SongCard = ({ 
  position, 
  songTitle = "Song Title", 
  artistName = "Artist Name",
  isSelected = false,
  isDisabled = false,
  onVote
}: SongCardProps) => {
  const handleTap = () => {
    if (!isDisabled && onVote) {
      onVote();
    }
  };

  const isLeft = position === 'left';
  const colorClass = isLeft ? 'song-a' : 'song-b';

  return (
    <div 
      className={`
        flex-1 flex flex-col items-center p-3 rounded-xl transition-all duration-200
        border-2
        ${isDisabled 
          ? 'opacity-50 cursor-not-allowed border-transparent' 
          : 'cursor-pointer active:scale-[0.98]'
        }
        ${isSelected 
          ? isLeft
            ? 'border-song-a glow-a bg-song-a/5'
            : 'border-song-b glow-b bg-song-b/5'
          : 'border-border/50 hover:border-border bg-card/50'
        }
      `}
      onClick={handleTap}
      role="button"
      aria-pressed={isSelected}
      aria-disabled={isDisabled}
      tabIndex={isDisabled ? -1 : 0}
    >
      {/* Album artwork placeholder */}
      <div 
        className={`
          w-full aspect-square rounded-lg flex items-center justify-center mb-4 
          transition-all duration-200 relative overflow-hidden
          ${isSelected 
            ? isLeft
              ? 'bg-gradient-to-br from-song-a/30 to-song-a/10'
              : 'bg-gradient-to-br from-song-b/30 to-song-b/10'
            : 'bg-secondary'
          }
        `}
      >
        <Music 
          className={`
            w-12 h-12 transition-colors duration-200
            ${isSelected 
              ? isLeft ? 'text-song-a' : 'text-song-b'
              : 'text-muted-foreground'
            }
          `} 
        />
      </div>
      
      {/* Song info */}
      <div className="text-center w-full space-y-1">
        <h3 
          className={`
            text-base font-semibold truncate transition-colors duration-200
            ${isSelected 
              ? isLeft ? 'text-song-a' : 'text-song-b'
              : 'text-foreground'
            }
          `}
        >
          {songTitle}
        </h3>
        <p className="text-sm text-muted-foreground truncate">
          {artistName}
        </p>
      </div>
    </div>
  );
};

export default SongCard;
