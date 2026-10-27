import { ArrowLeft } from "lucide-react";

interface BackButtonProps {
  onClick: () => void;
  // Optional text next to the arrow (e.g. "Lobby")
  label?: string;
}

// Neon round back arrow shared by the app-zone screens. The screen owns where
// it goes (onClick); this only draws it.
const BackButton = ({ onClick, label }: BackButtonProps) => (
  <button
    onClick={onClick}
    aria-label={label ?? "Back"}
    className="absolute top-4 left-4 z-10 flex items-center gap-1.5 h-10 rounded-full neon-outline px-3 text-sm text-foreground/85 hover:text-foreground hover:brightness-125 transition"
  >
    <ArrowLeft className="w-4 h-4" />
    {label && <span>{label}</span>}
  </button>
);

export default BackButton;
