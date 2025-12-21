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
          style: 'bg-background/95',
          titleStyle: 'text-4xl font-bold text-foreground'
        };
      case 'FINAL_30S':
        return {
          title: 'FINAL SECONDS',
          subtitle: 'Make your decision',
          style: 'bg-background/60',
          titleStyle: 'text-2xl font-semibold text-song-b'
        };
      case 'SUDDEN_DEATH':
        return {
          title: 'SUDDEN DEATH',
          subtitle: 'Every vote counts',
          style: 'bg-background/80',
          titleStyle: 'text-3xl font-bold text-destructive'
        };
      case 'FINISHED':
        return {
          title: 'BATTLE FINISHED',
          subtitle: 'Winner announced',
          style: 'bg-background/90',
          titleStyle: 'text-3xl font-bold text-foreground'
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
        ${content.style}
      `}
      aria-live="polite"
    >
      <h2 className={content.titleStyle}>
        {content.title}
      </h2>
      <p className="mt-2 text-muted-foreground text-sm">
        {content.subtitle}
      </p>
    </div>
  );
};

export default BattleStateOverlay;

export type { BattleState };
