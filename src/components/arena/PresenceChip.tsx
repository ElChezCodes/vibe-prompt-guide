import { PresenceState } from "@/integrations/supabase/presence";

const LABELS: Record<PresenceState, string> = {
  active: "Active",
  passive: "Passive",
  inactive: "Inactive",
};

// Display-only: the state is computed by the backend (get_arena_presence)
const PresenceChip = ({ state }: { state: PresenceState | null | undefined }) => {
  if (!state) return null;
  return (
    <span className="hud-chip px-3 py-1 rounded-full text-xs font-medium" data-presence={state}>
      {LABELS[state]}
    </span>
  );
};

export default PresenceChip;
