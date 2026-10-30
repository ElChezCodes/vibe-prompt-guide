import { PresenceState } from "@/integrations/supabase/presence";

export const PRESENCE_LABELS: Record<PresenceState, string> = {
  active: "Active",
  passive: "Passive",
  inactive: "Inactive",
};

export const PRESENCE_HINTS: Record<PresenceState, string> = {
  active: "You did something in the last 5 minutes",
  passive: "Connected, no action in 5 minutes",
  inactive: "Left or not connected",
};

// ACTIVO green, PASIVO amber, INACTIVO gray (same dots everywhere)
export const PRESENCE_DOTS: Record<PresenceState, string> = {
  active: "bg-primary shadow-[0_0_6px_hsl(var(--primary))] motion-safe:animate-pulse",
  passive: "bg-energy-yellow shadow-[0_0_6px_hsl(var(--energy-yellow)/0.8)]",
  inactive: "bg-muted-foreground/70",
};

export const PRESENCE_TEXT: Record<PresenceState, string> = {
  active: "text-primary",
  passive: "text-energy-yellow",
  inactive: "text-muted-foreground",
};

const RINGS: Record<PresenceState, string> = {
  active: "ring-1 ring-primary/40",
  passive: "ring-1 ring-energy-yellow/40",
  inactive: "ring-1 ring-muted-foreground/30",
};

// Display-only: the state is computed by the backend (get_arena_presence)
const PresenceChip = ({ state }: { state: PresenceState | null | undefined }) => {
  if (!state) return null;
  return (
    <span
      className={`hud-chip inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold leading-none ${RINGS[state]} ${PRESENCE_TEXT[state]}`}
      data-presence={state}
      title={PRESENCE_HINTS[state]}
      aria-label={`${PRESENCE_LABELS[state]}: ${PRESENCE_HINTS[state]}`}
    >
      <span aria-hidden className={`w-2.5 h-2.5 rounded-full flex-shrink-0 ${PRESENCE_DOTS[state]}`} />
      {PRESENCE_LABELS[state]}
    </span>
  );
};

export default PresenceChip;
