/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/Hnvr/Web/View/**/*.hs",
    "./src/Hnvr/Web/View/*.hs",
    "./static/src.css",
  ],
  darkMode: "class",
  theme: {
    extend: {
      fontFamily: {
        sans: [
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "Helvetica Neue",
          "Arial",
          "sans-serif",
        ],
        mono: [
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "Consolas",
          "Liberation Mono",
          "monospace",
        ],
      },
      colors: {
        // Security-console palette: 5-stop zinc + 3 accent hues
        ink: {
          950: "#09090b",
          900: "#0c0d10",
          875: "#13151a",
          850: "#181a20",
          800: "#1f222a",
          700: "#2a2e38",
          600: "#3a3f4b",
        },
        signal: {
          ok: "#22c55e",
          rec: "#ef4444",
          warn: "#f59e0b",
          info: "#38bdf8",
        },
      },
      boxShadow: {
        glow: "0 0 0 1px rgba(56,189,248,0.18), 0 0 14px rgba(56,189,248,0.18)",
        "glow-rec":
          "0 0 0 1px rgba(239,68,68,0.35), 0 0 16px rgba(239,68,68,0.45)",
        panel: "0 1px 0 rgba(255,255,255,0.04) inset, 0 8px 24px -16px rgba(0,0,0,0.6)",
      },
      keyframes: {
        pulseRec: {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.35" },
        },
        fadeIn: {
          "0%": { opacity: "0", transform: "translateY(2px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
      },
      animation: {
        "pulse-rec": "pulseRec 1.4s ease-in-out infinite",
        "fade-in": "fadeIn 0.18s ease-out",
      },
    },
  },
  plugins: [],
};
