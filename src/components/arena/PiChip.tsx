import { MyPi, PiAward, PI_REASON_LABELS } from "@/integrations/supabase/pi";

// Display-only (step 15): the caller's PI in this arena, and a short notice
// for awards that just arrived (decided by the backend).
const PiChip = ({ pi, notice }: { pi: MyPi | null; notice: PiAward[] }) => {
  if (!pi) return null;
  const gained = notice.reduce((sum, a) => sum + a.delta, 0);
  return (
    <>
      <span
        className="hud-chip inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium leading-none"
        title={`Total: ${pi.total_pi} PI`}
      >
        <span className="text-energy-yellow font-bold">PI</span>
        {pi.arena_pi}
      </span>
      {notice.length > 0 && (
        <span
          className="hud-chip inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-semibold leading-none animate-fade-in"
          data-pi-notice
        >
          <span className="text-energy-yellow">
            {gained >= 0 ? "+" : ""}
            {gained} PI
          </span>
          <span className="text-text-secondary font-normal">
            {Array.from(new Set(notice.map((a) => PI_REASON_LABELS[a.reason]))).join(" · ")}
          </span>
        </span>
      )}
    </>
  );
};

export default PiChip;
