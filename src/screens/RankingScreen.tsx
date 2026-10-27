import { Crown, Medal, Trophy } from "lucide-react";

// Placeholder (step 2b ships the navigation structure only). PI / ranking
// data comes with its own roadmap step: the podium is empty on purpose.
const PODIUM = [
  { place: 2, icon: Medal, height: "h-20", tone: "text-song-a", edge: "border-song-a/50" },
  { place: 1, icon: Crown, height: "h-28", tone: "text-energy-yellow", edge: "border-energy-yellow/60" },
  { place: 3, icon: Medal, height: "h-14", tone: "text-song-b", edge: "border-song-b/50" },
];

const RankingScreen = () => {
  return (
    <div className="min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center gap-8 px-6 py-12">
      <div className="text-center animate-fade-in-up">
        <Trophy className="mx-auto mb-3 w-10 h-10 text-energy-yellow" />
        <h1 className="neon-heading text-3xl">Ranking</h1>
      </div>

      {/* Empty podium */}
      <div
        className="w-full max-w-xs neon-panel rounded-2xl px-5 pt-8 pb-5 animate-fade-in-up"
        style={{ animationDelay: "100ms" }}
      >
        <div className="flex items-end justify-center gap-3">
          {PODIUM.map(({ place, icon: Icon, height, tone, edge }) => (
            <div key={place} className="flex-1 flex flex-col items-center gap-2">
              <div className={`w-12 h-12 rounded-full border-2 border-dashed ${edge} flex items-center justify-center`}>
                <span className="text-muted-foreground font-bold">?</span>
              </div>
              <div className={`w-full ${height} rounded-t-lg bg-secondary/80 border-t-2 ${edge} flex flex-col items-center justify-start pt-2`}>
                <Icon className={`w-5 h-5 ${tone}`} />
                <span className={`font-arcade font-black text-lg ${tone}`}>{place}</span>
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="text-center animate-fade-in-up" style={{ animationDelay: "200ms" }}>
        <p className="text-foreground font-semibold">Coming soon</p>
        <p className="mt-1 text-sm text-muted-foreground max-w-xs">
          The best song pickers of the night will show up here.
        </p>
      </div>
    </div>
  );
};

export default RankingScreen;
