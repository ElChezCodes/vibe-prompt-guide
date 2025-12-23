import { useEffect, useState } from "react";

type BattleState = 'INIT' | 'NORMAL' | 'FINAL_30S' | 'SUDDEN_DEATH' | 'FINISHED';

interface BattleStateOverlayProps {
  battleState: BattleState;
  winnerSide?: 'A' | 'B' | null;
}

const BattleStateOverlay = ({ battleState, winnerSide }: BattleStateOverlayProps) => {
  const [isVisible, setIsVisible] = useState(false);
  const [isExiting, setIsExiting] = useState(false);

  useEffect(() => {
    if (battleState === 'NORMAL') {
      setIsVisible(false);
      setIsExiting(false);
      return;
    }

    // Fade in
    setIsVisible(true);
    setIsExiting(false);

    // For INIT, auto-fade out after short duration
    if (battleState === 'INIT') {
      const exitTimer = setTimeout(() => {
        setIsExiting(true);
      }, 1200);
      
      const hideTimer = setTimeout(() => {
        setIsVisible(false);
      }, 1500);

      return () => {
        clearTimeout(exitTimer);
        clearTimeout(hideTimer);
      };
    }
  }, [battleState]);

  if (!isVisible && battleState === 'NORMAL') {
    return null;
  }

  const getOverlayContent = () => {
    switch (battleState) {
      case 'INIT':
        return {
          title: 'FIGHT!',
          subtitle: 'Get ready to vote',
          bgStyle: 'bg-background/95',
          titleStyle: 'text-5xl font-arcade font-black tracking-wider bg-gradient-to-r from-song-a via-primary to-song-b bg-clip-text text-transparent',
          animationStyle: ''
        };
      case 'FINAL_30S':
        return {
          title: 'FINAL SECONDS',
          subtitle: 'Make your decision now',
          bgStyle: 'bg-background/70',
          titleStyle: 'text-2xl font-arcade font-bold tracking-wide text-song-b text-glow-b',
          animationStyle: 'animate-emphasis-pulse'
        };
      case 'SUDDEN_DEATH':
        return {
          title: 'SUDDEN DEATH',
          subtitle: 'Every vote counts',
          bgStyle: 'bg-background/85',
          titleStyle: 'text-3xl font-arcade font-black tracking-wider text-destructive',
          animationStyle: 'animate-emphasis-pulse'
        };
      case 'FINISHED':
        return {
          title: winnerSide === 'A' ? 'BLUE WINS!' : winnerSide === 'B' ? 'PINK WINS!' : 'WINNER',
          subtitle: 'Battle complete',
          bgStyle: 'bg-background/90',
          titleStyle: `text-4xl font-arcade font-black tracking-wider ${winnerSide === 'A' ? 'text-song-a text-glow-a' : winnerSide === 'B' ? 'text-song-b text-glow-b' : 'text-primary'}`,
          animationStyle: ''
        };
      default:
        return null;
    }
  };

  const content = getOverlayContent();
  
  if (!content) return null;

  return (
    <div 
      className={`
        fixed inset-0 z-30 flex flex-col items-center justify-center
        ${content.bgStyle}
        ${isExiting ? 'animate-fade-out' : 'animate-fade-in'}
      `}
      aria-live="polite"
    >
      <h2 className={`${content.titleStyle} ${content.animationStyle}`}>
        {content.title}
      </h2>
      <p className={`mt-3 text-muted-foreground text-sm tracking-wide uppercase ${isExiting ? '' : 'animate-fade-in-up'}`}
         style={{ animationDelay: '0.1s' }}>
        {content.subtitle}
      </p>
    </div>
  );
};

export default BattleStateOverlay;

export type { BattleState };
