import { NavLink, Outlet } from "react-router-dom";
import { Home, Music, Swords, Trophy, User } from "lucide-react";
import { useCurrentArena } from "@/hooks/useCurrentArena";
import { arenaHomePath, arenaPath } from "@/lib/arenaRoutes";

// App zone: every screen except the Battle Room and the Stage View gets the
// bottom tab bar (Paso_2 §3 "no navigation" applies only inside the battle).
const AppShell = () => {
  const { data: current } = useCurrentArena();

  // Without a current arena, Arena/Proponer lead to Join
  const arenaTo = current ? arenaHomePath(current.arena_code, current.is_host, current.state) : "/join";
  const proposeTo = current ? arenaPath(current.arena_code, "propose") : "/join";

  const tabs = [
    { to: "/", label: "Home", icon: Home, end: true },
    { to: proposeTo, label: "Propose", icon: Music, end: false },
    { to: arenaTo, label: "Arena", icon: Swords, end: false },
    { to: "/ranking", label: "Ranking", icon: Trophy, end: false },
    { to: "/profile", label: "Profile", icon: User, end: false },
  ];

  return (
    <div className="min-h-dvh w-full space-bg pb-16">
      <Outlet />

      <nav className="fixed bottom-0 inset-x-0 z-50 h-16 tabbar-glass">
        <div className="mx-auto max-w-md h-full grid grid-cols-5">
          {tabs.map(({ to, label, icon: Icon, end }) => (
            <NavLink
              key={label}
              to={to}
              end={end}
              className={({ isActive }) =>
                `relative flex flex-col items-center justify-center gap-1 text-[11px] font-medium tracking-wide transition-colors ${
                  isActive ? "text-primary text-glow-primary" : "text-muted-foreground hover:text-song-a"
                }`
              }
            >
              {({ isActive }) => (
                <>
                  {isActive && (
                    <span
                      aria-hidden
                      className="absolute top-0 h-0.5 w-8 rounded-full bg-primary glow-primary"
                    />
                  )}
                  <span
                    className={`flex items-center justify-center w-9 h-7 rounded-lg transition-colors ${
                      isActive ? "bg-primary/15" : ""
                    }`}
                  >
                    <Icon className={`w-5 h-5 ${isActive ? "icon-glow-primary" : ""}`} />
                  </span>
                  {label}
                </>
              )}
            </NavLink>
          ))}
        </div>
      </nav>
    </div>
  );
};

export default AppShell;
