import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";

const SplashScreen = () => {
  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center bg-background px-6">
      <div className="flex flex-col items-center gap-8">
        {/* Logo */}
        <h1 className="font-arcade text-4xl sm:text-5xl text-primary tracking-wider text-center">
          MUSIC FIGHTER
        </h1>

        {/* Tagline */}
        <p className="text-text-secondary text-lg text-center max-w-xs">
          Battle your friends with songs
        </p>

        {/* Entry Action */}
        <Button asChild size="lg" className="mt-4 px-10">
          <Link to="/join">Enter Arena</Link>
        </Button>
      </div>
    </div>
  );
};

export default SplashScreen;
