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

  return (
    <div 
      className={`
        flex-1 flex flex-col items-center p-3 rounded-xl transition-colors
        ${isDisabled 
          ? 'opacity-50 cursor-not-allowed' 
          : 'cursor-pointer active:scale-[0.98]'
        }
        ${isSelected 
          ? position === 'left'
            ? 'ring-2 ring-song-a bg-song-a/10'
            : 'ring-2 ring-song-b bg-song-b/10'
          : 'bg-transparent'
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
          w-full aspect-square rounded-lg flex items-center justify-center mb-3 transition-colors
          ${isSelected 
            ? position === 'left'
              ? 'bg-song-a/20'
              : 'bg-song-b/20'
            : 'bg-secondary'
          }
        `}
      >
        <div className="w-12 h-12 rounded-full bg-muted" />
      </div>
      
      {/* Song info */}
      <div className="text-center w-full">
        <h3 className="text-sm font-semibold text-foreground truncate">
          {songTitle}
        </h3>
        <p className="text-xs text-muted-foreground truncate mt-1">
          {artistName}
        </p>
      </div>
    </div>
  );
};

export default SongCard;
