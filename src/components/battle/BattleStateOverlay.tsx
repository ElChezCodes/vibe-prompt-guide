type BattleState = 'INIT' | 'NORMAL' | 'FINAL_30S' | 'SUDDEN_DEATH' | 'FINISHED';

interface BattleStateOverlayProps {
  battleState: BattleState;
}

const BattleStateOverlay = ({ battleState }: BattleStateOverlayProps) => {
  if (battleState === 'NORMAL') {
    return null;
  }

  const getOverlayContent = () => {
    switch (battleState) {
      case 'INIT':
        return {
          title: 'FIGHT!',
          subtitle: 'Get ready to vote',
          bgStyle: 'bg-background/95',
          titleStyle: 'text-5xl font-arcade font-black tracking-wider bg-gradient-to-r from-song-a via-primary to-song-b bg-clip-text text-transparent'
        };
      case 'FINAL_30S':
        return {
          title: 'FINAL SECONDS',
          subtitle: 'Make your decision now',
          bgStyle: 'bg-background/70',
          titleStyle: 'text-2xl font-arcade font-bold tracking-wide text-song-b text-glow-b'
        };
      case 'SUDDEN_DEATH':
        return {
          title: 'SUDDEN DEATH',
          subtitle: 'Every vote counts',
          bgStyle: 'bg-background/85',
          titleStyle: 'text-3xl font-arcade font-black tracking-wider text-destructive'
        };
      case 'FINISHED':
        return {
          title: 'WINNER',
          subtitle: 'Battle complete',
          bgStyle: 'bg-background/90',
          titleStyle: 'text-4xl font-arcade font-black tracking-wider text-primary'
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
      `}
      aria-live="polite"
    >
      <h2 className={content.titleStyle}>
        {content.title}
      </h2>
      <p className="mt-3 text-muted-foreground text-sm tracking-wide uppercase">
        {content.subtitle}
      </p>
    </div>
  );
};

export default BattleStateOverlay;

export type { BattleState };
