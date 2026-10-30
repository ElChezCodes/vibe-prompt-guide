import type { Config } from "tailwindcss";
import tailwindcssAnimate from "tailwindcss-animate";

export default {
  darkMode: ["class"],
  content: ["./pages/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}", "./app/**/*.{ts,tsx}", "./src/**/*.{ts,tsx}"],
  prefix: "",
  theme: {
    container: {
      center: true,
      padding: "2rem",
      screens: {
        "2xl": "1400px",
      },
    },
    extend: {
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        arcade: ['Orbitron', 'sans-serif'],
      },
      colors: {
        border: "hsl(var(--border))",
        input: "hsl(var(--input))",
        ring: "hsl(var(--ring))",
        background: "hsl(var(--background))",
        foreground: "hsl(var(--foreground))",
        surface: "hsl(var(--surface))",
        "text-secondary": "hsl(var(--text-secondary))",
        primary: {
          DEFAULT: "hsl(var(--primary))",
          hover: "hsl(var(--primary-hover))",
          foreground: "hsl(var(--primary-foreground))",
        },
        secondary: {
          DEFAULT: "hsl(var(--secondary))",
          foreground: "hsl(var(--secondary-foreground))",
        },
        destructive: {
          DEFAULT: "hsl(var(--destructive))",
          foreground: "hsl(var(--destructive-foreground))",
        },
        muted: {
          DEFAULT: "hsl(var(--muted))",
          foreground: "hsl(var(--muted-foreground))",
        },
        accent: {
          DEFAULT: "hsl(var(--accent))",
          foreground: "hsl(var(--accent-foreground))",
        },
        popover: {
          DEFAULT: "hsl(var(--popover))",
          foreground: "hsl(var(--popover-foreground))",
        },
        card: {
          DEFAULT: "hsl(var(--card))",
          foreground: "hsl(var(--card-foreground))",
        },
        sidebar: {
          DEFAULT: "hsl(var(--sidebar-background))",
          foreground: "hsl(var(--sidebar-foreground))",
          primary: "hsl(var(--sidebar-primary))",
          "primary-foreground": "hsl(var(--sidebar-primary-foreground))",
          accent: "hsl(var(--sidebar-accent))",
          "accent-foreground": "hsl(var(--sidebar-accent-foreground))",
          border: "hsl(var(--sidebar-border))",
          ring: "hsl(var(--sidebar-ring))",
        },
        "song-a": {
          DEFAULT: "hsl(var(--song-a))",
          glow: "hsl(var(--song-a-glow))",
          soft: "hsl(var(--song-a-soft) / 0.15)",
          foreground: "hsl(var(--song-a-foreground))",
        },
        "song-b": {
          DEFAULT: "hsl(var(--song-b))",
          glow: "hsl(var(--song-b-glow))",
          soft: "hsl(var(--song-b-soft) / 0.15)",
          foreground: "hsl(var(--song-b-foreground))",
        },
        energy: {
          yellow: "hsl(var(--energy-yellow))",
          orange: "hsl(var(--energy-orange))",
        },
        nebula: {
          DEFAULT: "hsl(var(--nebula))",
          glow: "hsl(var(--nebula-glow))",
        },
      },
      borderRadius: {
        lg: "var(--radius)",
        md: "calc(var(--radius) - 2px)",
        sm: "calc(var(--radius) - 4px)",
      },
      keyframes: {
        "accordion-down": {
          from: { height: "0" },
          to: { height: "var(--radix-accordion-content-height)" },
        },
        "accordion-up": {
          from: { height: "var(--radix-accordion-content-height)" },
          to: { height: "0" },
        },
        "fade-in-up": {
          "0%": { opacity: "0", transform: "translateY(12px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        "fade-in": {
          "0%": { opacity: "0" },
          "100%": { opacity: "1" },
        },
        "fade-out": {
          "0%": { opacity: "1" },
          "100%": { opacity: "0" },
        },
        "scale-up": {
          "0%": { transform: "scale(1)" },
          "100%": { transform: "scale(1.02)" },
        },
        "vote-tap": {
          "0%": { transform: "scale(1)" },
          "50%": { transform: "scale(1.03)" },
          "100%": { transform: "scale(1)" },
        },
        "tension-oscillate": {
          "0%, 100%": { transform: "translateX(0)" },
          "25%": { transform: "translateX(-1px)" },
          "75%": { transform: "translateX(1px)" },
        },
        "tension-oscillate-intense": {
          "0%, 100%": { transform: "translateX(0)" },
          "25%": { transform: "translateX(-2px)" },
          "75%": { transform: "translateX(2px)" },
        },
        "tension-oscillate-tight": {
          "0%, 100%": { transform: "translateX(0)" },
          "20%": { transform: "translateX(-1.5px)" },
          "40%": { transform: "translateX(1px)" },
          "60%": { transform: "translateX(-1px)" },
          "80%": { transform: "translateX(1.5px)" },
        },
        "slide-out-left": {
          "0%": { transform: "translateX(0)", opacity: "1" },
          "100%": { transform: "translateX(-100%)", opacity: "1" },
        },
        "slide-out-right": {
          "0%": { transform: "translateX(0)", opacity: "1" },
          "100%": { transform: "translateX(100%)", opacity: "1" },
        },
        "winner-center": {
          "0%": { transform: "translateX(0) scale(1)" },
          "100%": { transform: "translateX(var(--winner-translate)) scale(1.35)" },
        },
        "glow-pulse": {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.7" },
        },
        "emphasis-pulse": {
          "0%, 100%": { opacity: "1", transform: "scale(1)" },
          "50%": { opacity: "0.9", transform: "scale(1.02)" },
        },
      },
      animation: {
        "accordion-down": "accordion-down 0.2s ease-out",
        "accordion-up": "accordion-up 0.2s ease-out",
        "fade-in-up": "fade-in-up 0.4s cubic-bezier(0.33, 1, 0.68, 1)",
        "fade-in": "fade-in 0.3s cubic-bezier(0.33, 1, 0.68, 1)",
        "fade-out": "fade-out 0.3s cubic-bezier(0.33, 1, 0.68, 1)",
        "scale-up": "scale-up 0.15s cubic-bezier(0.33, 1, 0.68, 1)",
        "vote-tap": "vote-tap 0.2s cubic-bezier(0.33, 1, 0.68, 1)",
        "tension-normal": "tension-oscillate 3s ease-in-out infinite",
        "tension-final": "tension-oscillate-intense 2s ease-in-out infinite",
        "tension-sudden": "tension-oscillate-tight 0.8s ease-in-out infinite",
        "slide-out-left": "slide-out-left 0.35s cubic-bezier(0.33, 1, 0.68, 1) forwards",
        "slide-out-right": "slide-out-right 0.35s cubic-bezier(0.33, 1, 0.68, 1) forwards",
        "winner-center": "winner-center 0.4s cubic-bezier(0.33, 1, 0.68, 1) forwards",
        "glow-pulse": "glow-pulse 1.5s ease-in-out",
        "emphasis-pulse": "emphasis-pulse 0.6s cubic-bezier(0.33, 1, 0.68, 1)",
      },
    },
  },
  plugins: [tailwindcssAnimate],
} satisfies Config;
