import { ReactNode, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Crown, Loader2, Trophy } from "lucide-react";
import { useCurrentArena } from "@/hooks/useCurrentArena";
import {
  ArenaPiRow,
  getArenaPiLeaderboard,
  getMyPastArenas,
  getMyProfile,
  getPiLeaderboard,
  GlobalPiRow,
  MyProfile,
  PastArena,
  PiPeriod,
  PiScope,
} from "@/integrations/supabase/pi";
import { countryName } from "@/lib/countries";

type Tab = "local" | PiScope;

const TABS: { id: Tab; label: string }[] = [
  { id: "local", label: "Arena" },
  { id: "country", label: "Country" },
  { id: "world", label: "World" },
];

const PERIODS: { id: PiPeriod; label: string }[] = [
  { id: "month", label: "This month" },
  { id: "all", label: "All time" },
];

// Rows are decided by the backend (step 15): place, name and PI only
// Podium (crown, colours) only with PI: with everyone at 0 all tie at place 1
const RankRow = ({ place, name, pi, isMe, note }: { place: number; name: string; pi: number; isMe: boolean; note?: string }) => {
  const podium = pi > 0 && place <= 3;
  return (
  <li
    className={`flex items-center gap-3 rounded-lg neon-row ${podium ? `podium-${place} px-3 py-2.5` : "px-3 py-2"} ${
      isMe ? "rank-me" : ""
    }`}
    data-me={isMe || undefined}
  >
    <span className={`w-8 shrink-0 text-center font-arcade font-black ${podium ? "podium-badge text-lg" : "text-sm text-muted-foreground"}`}>
      {podium && place === 1 ? <Crown className="inline w-5 h-5" /> : place}
    </span>
    <span className={`flex-1 min-w-0 truncate text-foreground ${podium ? "font-semibold" : ""}`}>
      {name}
      {isMe && <span className="ml-1.5 text-[10px] font-arcade uppercase tracking-wider text-primary">you</span>}
      {note && <span className="ml-1.5 text-[10px] uppercase tracking-wider text-muted-foreground">{note}</span>}
    </span>
    <span className="font-arcade font-bold tabular-nums text-foreground whitespace-nowrap">
      {pi} <span className="text-[10px] text-energy-yellow">PI</span>
    </span>
  </li>
  );
};

const Empty = ({ children }: { children: ReactNode }) => (
  <div className="py-8 flex flex-col items-center gap-2 text-center">
    <Trophy className="w-8 h-8 text-muted-foreground/40" />
    <p className="max-w-[16rem] text-sm text-muted-foreground">{children}</p>
  </div>
);

const ArenaBoard = ({ arenaId }: { arenaId: string }) => {
  const [rows, setRows] = useState<ArenaPiRow[] | null>(null);
  useEffect(() => {
    setRows(null);
    getArenaPiLeaderboard(arenaId).then(setRows);
  }, [arenaId]);
  if (!rows) return <Loader2 className="mx-auto my-6 w-5 h-5 animate-spin text-muted-foreground" />;
  if (!rows.length) return <Empty>No players yet</Empty>;
  return (
    <ol className="space-y-2">
      {rows.map((r, i) => (
        <RankRow key={i} place={r.place} name={r.display_name} pi={r.pi} isMe={r.is_me} note={r.is_host ? "host" : undefined} />
      ))}
    </ol>
  );
};

const LocalTab = () => {
  const { data: current } = useCurrentArena();
  const [past, setPast] = useState<PastArena[]>([]);
  const [selected, setSelected] = useState<string | null>(null);

  useEffect(() => {
    getMyPastArenas().then(setPast);
  }, []);

  const arenaId = selected ?? current?.arena_id ?? null;
  const selectedPast = past.find((a) => a.arena_id === arenaId);

  return (
    <div className="space-y-4">
      {arenaId ? (
        <div className="space-y-2">
          <p className="flex items-center gap-2 text-sm font-semibold text-foreground truncate">
            {selectedPast ? selectedPast.name : current?.name}
            {!selectedPast && (
              <span className="inline-flex items-center gap-1 rounded-full bg-primary/15 px-2 py-0.5 text-[10px] font-arcade uppercase tracking-wider text-primary">
                <span className="h-1.5 w-1.5 rounded-full bg-primary animate-pulse" />
                live
              </span>
            )}
          </p>
          <ArenaBoard arenaId={arenaId} />
          {selected && current && selected !== current.arena_id && (
            <button className="text-xs text-primary underline" onClick={() => setSelected(null)}>
              Back to {current.name}
            </button>
          )}
        </div>
      ) : (
        <Empty>
          You're not in an arena. <Link to="/join" className="underline text-primary">Join one</Link> to compete.
        </Empty>
      )}

      {past.length > 0 && (
        <div className="space-y-2">
          <p className="neon-label">Past arenas</p>
          <ul className="grid grid-cols-1 gap-2">
            {past.map((a) => (
              <li key={a.arena_id}>
                <button
                  onClick={() => setSelected(a.arena_id)}
                  className={`w-full flex items-center gap-3 px-3 py-2 rounded-xl neon-row text-left transition-colors ${
                    a.arena_id === arenaId ? "rank-me" : ""
                  }`}
                >
                  <span className="flex-1 min-w-0">
                    <span className="block truncate text-foreground">{a.name}</span>
                    <span className="block text-[11px] text-muted-foreground">
                      {new Date(a.ended_at).toLocaleDateString()} · {a.players} players
                    </span>
                  </span>
                  {a.my_place != null && (
                    <span className="flex flex-col items-end leading-tight whitespace-nowrap">
                      <span className="font-arcade font-black text-foreground">#{a.my_place}</span>
                      <span className="text-[11px] tabular-nums text-muted-foreground">
                        {a.my_pi} <span className="text-energy-yellow">PI</span>
                      </span>
                    </span>
                  )}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
};

const GlobalTab = ({ scope, profile }: { scope: PiScope; profile: MyProfile | null }) => {
  const [period, setPeriod] = useState<PiPeriod>("month");
  const [rows, setRows] = useState<GlobalPiRow[] | null>(null);

  const needsCountry = scope === "country" && !profile?.country;

  useEffect(() => {
    if (needsCountry) return;
    setRows(null);
    getPiLeaderboard(scope, period).then(setRows);
  }, [scope, period, needsCountry]);

  if (!profile) return <Loader2 className="mx-auto my-6 w-5 h-5 animate-spin text-muted-foreground" />;

  return (
    <div className="space-y-3">
      <div className="scoreboard grid grid-cols-2 gap-1 rounded-lg p-1">
        {PERIODS.map((p) => (
          <button
            key={p.id}
            onClick={() => setPeriod(p.id)}
            className="scoreboard-tab"
            aria-pressed={period === p.id}
          >
            {p.label}
          </button>
        ))}
      </div>
      {scope === "country" && profile.country && (
        <p className="text-sm text-text-secondary">{countryName(profile.country)}</p>
      )}

      {!profile.is_account && (
        <p className="text-xs text-muted-foreground">
          Only accounts appear here. <Link to="/profile" className="underline text-primary">Create one in Profile</Link>{" "}
          to join with the PI you earned.
        </p>
      )}

      {needsCountry ? (
        <Empty>
          Choose your country in <Link to="/profile" className="underline text-primary">Profile</Link> to see this ranking.
        </Empty>
      ) : !rows ? (
        <Loader2 className="mx-auto my-6 w-5 h-5 animate-spin text-muted-foreground" />
      ) : !rows.length ? (
        <Empty>No PI earned yet {period === "month" ? "this month" : ""}</Empty>
      ) : (
        <ol className="space-y-2">
          {rows.map((r, i) => (
            <RankRow
              key={i}
              place={r.place}
              name={r.display_name}
              pi={r.pi}
              isMe={r.is_me}
              note={scope === "world" && r.country ? r.country : undefined}
            />
          ))}
        </ol>
      )}
    </div>
  );
};

// Step 15: local (per arena, current + past) and global (country / world,
// accounts only) PI leaderboards. Minimal markup; the visual pass is in Lovable.
const RankingScreen = () => {
  const [tab, setTab] = useState<Tab>("local");
  const [profile, setProfile] = useState<MyProfile | null>(null);

  useEffect(() => {
    getMyProfile().then(setProfile);
  }, []);

  return (
    <div className="min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center gap-6 px-4 sm:px-6 py-10">
      <div className="text-center animate-fade-in-up">
        <Trophy className="mx-auto mb-3 w-10 h-10 text-energy-yellow" />
        <h1 className="neon-heading text-3xl">Ranking</h1>
        {profile && (
          <p className="mt-2 text-sm text-text-secondary">
            {profile.nickname} · <span className="font-semibold text-foreground">{profile.total_pi}</span>{" "}
            <span className="text-xs text-energy-yellow">PI</span>
          </p>
        )}
      </div>

      <div className="w-full max-w-md neon-panel rounded-2xl p-4 sm:p-5 space-y-4">
        <div className="scoreboard grid grid-cols-3 gap-1 rounded-xl p-1" role="tablist">
          {TABS.map((t) => (
            <button
              key={t.id}
              role="tab"
              aria-selected={tab === t.id}
              onClick={() => setTab(t.id)}
              className="scoreboard-tab"
            >
              {t.label}
            </button>
          ))}
        </div>

        {tab === "local" ? <LocalTab /> : <GlobalTab scope={tab} profile={profile} />}
      </div>

      <p className="max-w-xs text-center text-xs text-muted-foreground">
        PI: +1 when your song reaches a battle, +10 when it wins (+5 in Sudden Death), 5 each in a draw (+5 Sudden Death), half when a
        song you backed wins with your vote. Wins count when someone else voted in the battle; the +1 needs 2+ people in the arena and isn't given for songs proposed in the lobby.
      </p>
    </div>
  );
};

export default RankingScreen;
