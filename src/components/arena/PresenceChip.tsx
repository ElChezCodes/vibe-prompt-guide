import { PresenceState } from "@/integrations/supabase/presence";

const LABELS: Record<PresenceState, string> = {
  active: "Active",
  passive: "Passive",
  inactive: "Inactive",
};

// ACTIVO green, PASIVO amber, INACTIVO gray
const DOTS: Record<PresenceState, string> = {
  active: "bg-primary shadow-[0_0_6px_hsl(var(--primary))]",
  passive: "bg-energy-yellow shadow-[0_0_6px_hsl(var(--energy-yellow)/0.8)]",
  inactive: "bg-muted-foreground/70",
};

// Display-only: the state is computed by the backend (get_arena_presence)
const PresenceChip = ({ state }: { state: PresenceState | null | undefined }) => {
  if (!state) return null;
  return (
    <span
      className="hud-chip inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium leading-none"
      data-presence={state}
    >
      <span aria-hidden className={`w-2 h-2 rounded-full flex-shrink-0 ${DOTS[state]}`} />
      {LABELS[state]}
    </span>
  );
};

export default PresenceChip;
