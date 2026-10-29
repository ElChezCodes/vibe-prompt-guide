import { MyPi, PiAward, PI_REASON_LABELS } from "@/integrations/supabase/pi";

// Display-only (step 15): the caller's PI in this arena, and a short notice
// for awards that just arrived (decided by the backend).
const PiChip = ({ pi, notice }: { pi: MyPi | null; notice: PiAward[] }) => {
  if (!pi) return null;
  const gained = notice.reduce((sum, a) => sum + a.delta, 0);
  return (
    <>
      <span
        className="hud-chip inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-arcade font-bold tabular-nums leading-none"
        title={`Total: ${pi.total_pi} PI`}
      >
        <span className="text-energy-yellow text-[10px]">PI</span>
        {pi.arena_pi}
      </span>
      {notice.length > 0 && (
        <span
          className="pi-pop inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold leading-none bg-energy-yellow/15 border border-energy-yellow/60 max-w-[14rem]"
          data-pi-notice
        >
          <span className="text-energy-yellow font-arcade font-black whitespace-nowrap">
            {gained >= 0 ? "+" : ""}
            {gained} PI
          </span>
          <span className="text-text-secondary font-normal truncate">
            {Array.from(new Set(notice.map((a) => PI_REASON_LABELS[a.reason]))).join(" · ")}
          </span>
        </span>
      )}
    </>
  );
};

export default PiChip;
