// The Home screen's corner notes (user's drawings, 2026-11-06), as vectors so
// they stay sharp and take the app's colors: currentColor + the glow classes.

interface NoteProps {
  className?: string;
}

// Three beamed notes
export const BeamedNotes = ({ className }: NoteProps) => (
  <svg viewBox="8 20 143 93" className={className} fill="currentColor" aria-hidden>
    <rect x="34.5" y="22" width="115" height="13" />
    <rect x="34.5" y="22" width="5" height="79" />
    <rect x="87.5" y="22" width="5" height="79" />
    <rect x="144.5" y="22" width="5" height="79" />
    <ellipse cx="24" cy="100" rx="15.5" ry="10.5" transform="rotate(-25 24 100)" />
    <ellipse cx="77" cy="100" rx="15.5" ry="10.5" transform="rotate(-25 77 100)" />
    <ellipse cx="134" cy="100" rx="15.5" ry="10.5" transform="rotate(-25 134 100)" />
  </svg>
);

// One note with a double flag (the "fusa"); the slit separates the two flags
export const FlaggedNote = ({ className }: NoteProps) => (
  <svg viewBox="30 10 102 148" className={className} fill="currentColor" aria-hidden>
    <rect x="75" y="13" width="5.5" height="128" />
    <ellipse cx="56.5" cy="139" rx="23.5" ry="16" transform="rotate(-25 56.5 139)" />
    <path
      fillRule="evenodd"
      d="M78 13 C82 28 100 33 112 44 C128 58 132 90 113 114 C118 95 116 80 106 69 C97 59 88 56 78 56 Z
         M87 42 C97 45 108 53 115 64 C106 58 97 53 86 48 Z"
    />
  </svg>
);
