import { Music } from "lucide-react";
import { useState } from "react";

type CardAnimationState = 'idle' | 'voting' | 'winner' | 'loser';

interface SongCardProps {
  position: 'left' | 'right';
  songTitle?: string;
  artistName?: string;
  isSelected?: boolean;
  isDisabled?: boolean;
  animationState?: CardAnimationState;
  onVote?: () => void;
}

const SongCard = ({ 
  position, 
  songTitle = "Song Title", 
  artistName = "Artist Name",
  isSelected = false,
  isDisabled = false,
  animationState = 'idle',
  onVote
}: SongCardProps) => {
  const [isAnimating, setIsAnimating] = useState(false);

  const handleTap = () => {
    if (!isDisabled && onVote) {
      setIsAnimating(true);
      onVote();
      // Reset animation state after animation completes
      setTimeout(() => setIsAnimating(false), 200);
    }
  };

  const isLeft = position === 'left';

  const getAnimationClass = () => {
    if (animationState === 'loser') {
      return isLeft ? 'animate-slide-out-left' : 'animate-slide-out-right';
    }
    if (animationState === 'winner') {
      return 'animate-winner-center';
    }
    if (isAnimating) {
      return 'animate-vote-tap';
    }
    return '';
  };

  const getWinnerStyle = () => {
    if (animationState === 'winner') {
      // Winner card moves toward center
      return {
        '--winner-translate': isLeft ? '25%' : '-25%',
      } as React.CSSProperties;
    }
    return {};
  };

  return (
    <div 
      className={`
        flex-1 flex flex-col items-center p-3 rounded-xl
        border-2 transition-[border-color,background-color,opacity,box-shadow] duration-200 ease-out
        ${getAnimationClass()}
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
        ${animationState === 'winner' ? (isLeft ? 'glow-a' : 'glow-b') : ''}
      `}
      style={getWinnerStyle()}
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
          transition-all duration-200 ease-out relative overflow-hidden
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
            w-12 h-12 transition-colors duration-200 ease-out
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
            text-base font-semibold truncate transition-colors duration-200 ease-out
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

export type { CardAnimationState };
