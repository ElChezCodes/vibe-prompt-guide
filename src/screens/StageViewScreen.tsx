import { useEffect } from "react";
import { useParams } from "react-router-dom";
import { QRCodeSVG } from "qrcode.react";
import { Pause, Users, Trophy } from "lucide-react";
import StageView from "@/components/battle/StageView";
import NextUpList from "@/components/battle/NextUpList";
import SpotifyTrackRow from "@/components/streaming/SpotifyTrackRow";
import ScreenMessage from "@/components/nav/ScreenMessage";
import { useBattleOrchestrator } from "@/hooks/useBattleOrchestrator";
import { useStageView } from "@/hooks/useStageView";
import { getDerivedBattlePhase } from "@/lib/derivedBattlePhase";
import { joinUrl } from "@/lib/arenaRoutes";
import { StageViewData } from "@/integrations/supabase/stageView";
import { PAUSE_REASON_LABELS, PauseReason } from "@/integrations/supabase/spotify";

const spotifyUrl = (trackId: string) => `https://open.spotify.com/track/${trackId}`;

/**
 * Step 19a: the party's shared screen (TV / projector), opened by anyone with
 * the link (/a/:code/stage). Read-only and never a participant: no heartbeat
 * (App.tsx skips /stage), no presence, no votes. Battle data comes from the
 * same backend view as the Battle Room (useBattleOrchestrator); everything
 * around it from get_stage_view (database only, no Spotify calls). No
 * playback controls: the host keeps those on their phone and in Spotify.
 */
const StageViewScreen = () => {
  const { code = "" } = useParams();
  const { data, status } = useStageView(code);
  const { battle, initBattleLoop, stopBattleLoop } = useBattleOrchestrator();

  const arenaId = data?.arena.id;
  const isActive = data?.arena.state === "active";
  useEffect(() => {
    if (!arenaId || !isActive) return;
    initBattleLoop(arenaId);
    return () => stopBattleLoop();
  }, [arenaId, isActive, initBattleLoop, stopBattleLoop]);

  if (status === "loading") return <ScreenMessage message="Loading..." showHomeButton={false} />;
  if (status === "not_found" || !data) return <ScreenMessage message="Arena not found" isError showHomeButton={false} />;

  if (data.arena.state === "waiting") return <StageLobby data={data} />;
  if (data.arena.state === "finished") return <StageFinished data={data} />;

  // Credits belong to the battle on screen only (the poll may lag a new battle)
  const credits = battle && data.battle?.battle_id === battle.battle_id ? data.battle : null;

  return (
    <div className="min-h-dvh w-full bg-background lg:grid lg:grid-cols-[minmax(0,1fr)_24rem]">
      <div className="relative min-w-0">
        <StageView
          key={battle?.battle_id}
          arena={{ id: data.arena.id, name: data.arena.name, state: data.arena.state, mood: data.arena.mood }}
          battle={battle}
          derivedPhase={getDerivedBattlePhase(battle)}
          pausedAt={data.arena.paused_at}
          shared
          credits={credits}
        />
        <StageStatusBanner data={data} />
      </div>
      <aside className="flex flex-col gap-5 p-4 sm:p-6 lg:border-l lg:border-border/60 lg:max-h-dvh lg:overflow-y-auto">
        <JoinCard code={data.arena.code} size={112} />
        <NowPlayingCard data={data} />
        <PeopleCard data={data} />
        {data.next_up.length > 0 && (
          <section>
            <h2 className="text-sm font-semibold uppercase tracking-wide text-text-secondary mb-2">Next up to fight</h2>
            <NextUpList songs={data.next_up} iconOnlyLink />
          </section>
        )}
        <Leaderboard rows={data.leaderboard} title="Top PI" />
      </aside>
    </div>
  );
};

// Paused (step 6 frozen clock) or no pair to fight yet: over the battle, not
// covering the tension bar or the cards' artwork
const StageStatusBanner = ({ data }: { data: StageViewData }) => {
  let text: string | null = null;
  if (data.arena.paused_at) {
    const reason = PAUSE_REASON_LABELS[data.arena.pause_reason as PauseReason];
    text = `Paused${reason ? ` · ${reason}` : ""}. Voting resumes when the music does.`;
  } else if (data.waiting_for_songs) {
    text = "Waiting for songs · propose one from your phone";
  }
  if (!text) return null;
  return (
    <div className="absolute inset-x-0 bottom-4 flex justify-center px-4 pointer-events-none">
      <div className="flex items-center gap-2 px-4 py-2 rounded-xl neon-panel text-sm lg:text-lg text-foreground">
        {data.arena.paused_at && <Pause className="h-4 w-4 lg:h-5 lg:w-5" />}
        {text}
      </div>
    </div>
  );
};

const JoinCard = ({ code, size }: { code: string; size: number }) => (
  <div className="flex items-center gap-4">
    {/* Black on white with a quiet zone so phones read it */}
    <div className="bg-white rounded-xl p-2 flex-shrink-0">
      <QRCodeSVG value={joinUrl(code)} size={size} marginSize={1} />
    </div>
    <div className="min-w-0">
      <p className="text-sm text-text-secondary">Scan to join, or enter the code</p>
      <p className="font-mono font-bold text-2xl lg:text-3xl tracking-widest text-foreground">{code}</p>
    </div>
  </div>
);

// What the host's Spotify plays (warm-up or a winner) and what follows; from
// what spotify-host already stored, no Spotify call
const NowPlayingCard = ({ data }: { data: StageViewData }) => {
  const pb = data.playback;
  if (!pb?.now_playing_title) return null;
  return (
    <section>
      <h2 className="text-sm font-semibold uppercase tracking-wide text-text-secondary mb-2">
        {pb.now_playing_kind === "warmup" ? "Now playing · warm-up" : "Now playing · winner"}
      </h2>
      <SpotifyTrackRow
        track={{
          title: pb.now_playing_title,
          artist: pb.now_playing_artist ?? "",
          artwork_url: pb.now_playing_artwork_url,
          spotify_url: pb.now_playing_spotify_track_id ? spotifyUrl(pb.now_playing_spotify_track_id) : null,
        }}
        iconOnlyLink
      />
      {pb.next_title && (
        <p className="mt-2 text-sm text-text-secondary truncate">
          Then: <span className="text-foreground">{pb.next_title}</span> · {pb.next_artist}
        </p>
      )}
      {pb.unplayable_title && (
        <p className="mt-1 text-xs text-text-secondary truncate">
          "{pb.unplayable_title}" isn't available in the host's country: skipped
        </p>
      )}
    </section>
  );
};

const PeopleCard = ({ data }: { data: StageViewData }) => (
  <div className="flex items-center gap-2 text-sm text-text-secondary">
    <Users className="h-4 w-4" />
    <span>
      <span className="text-foreground font-semibold">{data.people.joined}</span> in the arena ·{" "}
      {data.people.active} active · {data.people.passive} listening
    </span>
  </div>
);

const Leaderboard = ({ rows, title }: { rows: StageViewData["leaderboard"]; title: string }) => {
  if (rows.length === 0) return null;
  return (
    <section>
      <h2 className="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-text-secondary mb-2">
        <Trophy className="h-4 w-4" />
        {title}
      </h2>
      <ol className="space-y-1">
        {rows.map((r, i) => (
          <li key={`${r.display_name}-${i}`} className="flex items-center gap-3 text-base lg:text-lg">
            <span className="w-6 text-right tabular-nums text-text-secondary">{r.place}</span>
            <span className="flex-1 min-w-0 truncate text-foreground">
              {r.display_name}
              {r.is_host && <span className="ml-2 text-xs uppercase text-text-secondary">host</span>}
            </span>
            <span className="tabular-nums font-semibold text-foreground">{r.pi} PI</span>
          </li>
        ))}
      </ol>
    </section>
  );
};

// Before Start: how to join, the warm-up that will open the playlist, who is in
const StageLobby = ({ data }: { data: StageViewData }) => (
  <div className="min-h-dvh w-full space-bg flex flex-col items-center justify-center gap-8 px-4 py-8 text-center">
    <div>
      <h1 className="text-3xl lg:text-6xl font-arcade font-black text-foreground">{data.arena.name}</h1>
      <p className="mt-2 text-base lg:text-2xl text-text-secondary">Waiting for the host to start the battles</p>
    </div>
    <div className="flex flex-col items-center gap-3">
      <div className="bg-white rounded-2xl p-4">
        <QRCodeSVG value={joinUrl(data.arena.code)} size={240} marginSize={1} />
      </div>
      <p className="text-base lg:text-xl text-text-secondary">Scan to join, or enter the code</p>
      <p className="font-mono font-bold text-4xl lg:text-6xl tracking-widest text-foreground">{data.arena.code}</p>
    </div>
    <div className="w-full max-w-md flex flex-col gap-4 text-left">
      {data.warmup && (
        <section>
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-secondary mb-2">Warm-up song</h2>
          <SpotifyTrackRow
            track={{
              title: data.warmup.title,
              artist: data.warmup.artist,
              artwork_url: data.warmup.artwork_url,
              spotify_url: data.warmup.spotify_track_id ? spotifyUrl(data.warmup.spotify_track_id) : null,
            }}
            iconOnlyLink
          />
        </section>
      )}
      <PeopleCard data={data} />
      {data.next_up.length > 0 && (
        <section>
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-secondary mb-2">Next up to fight</h2>
          <NextUpList songs={data.next_up} iconOnlyLink />
        </section>
      )}
    </div>
  </div>
);

// After End Arena: the final ranking of the arena
const StageFinished = ({ data }: { data: StageViewData }) => (
  <div className="min-h-dvh w-full space-bg flex flex-col items-center justify-center gap-8 px-4 py-8">
    <div className="text-center">
      <h1 className="text-3xl lg:text-6xl font-arcade font-black text-foreground">{data.arena.name}</h1>
      <p className="mt-2 text-base lg:text-2xl text-text-secondary">Arena finished · thanks for playing</p>
    </div>
    <div className="w-full max-w-md">
      {data.leaderboard.length > 0 ? (
        <Leaderboard rows={data.leaderboard} title="Final ranking" />
      ) : (
        <p className="text-center text-text-secondary">No PI was won in this arena</p>
      )}
    </div>
  </div>
);

export default StageViewScreen;
