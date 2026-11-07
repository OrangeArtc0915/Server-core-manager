/**
 * Shared palette used across the TUI.
 *
 * `PAL` is a mutable object: `applyTheme()` overwrites its fields in place, so
 * every module that imports `PAL` (or reads it at render time) picks up the new
 * colors without re-importing. Modules that snapshot colors at load time must
 * read from `PAL` lazily instead (see syntax.ts / log_style.ts).
 *
 * None of the themes use pure black — a slate base keeps the console readable.
 */
export interface Palette {
  bg: string;
  panel: string;
  panelAlt: string;
  border: string;
  borderFocus: string;
  text: string;
  bright: string;
  muted: string;
  dim: string;
  accent: string;
  accent2: string;
  selectBg: string;
  selectFg: string;
  green: string;
  yellow: string;
  orange: string;
  red: string;
  cyan: string;
  magenta: string;
}

export interface ThemeDef {
  id: string;
  label: string;
  palette: Palette;
}

export const THEMES: ThemeDef[] = [
  {
    id: "night",
    label: "Night（蓝紫）",
    palette: {
      bg: "#1a1b26",
      panel: "#16161e",
      panelAlt: "#24283b",
      border: "#3b4261",
      borderFocus: "#7aa2f7",
      text: "#c0caf5",
      bright: "#ffffff",
      muted: "#9aa5ce",
      dim: "#6c7086",
      accent: "#7aa2f7",
      accent2: "#9ece6a",
      selectBg: "#3d59a1",
      selectFg: "#ffffff",
      green: "#9ece6a",
      yellow: "#e0af68",
      orange: "#ff9e64",
      red: "#f7768e",
      cyan: "#7dcfff",
      magenta: "#bb9af7"
    }
  },
  {
    id: "one",
    label: "One Dark（青橙）",
    palette: {
      bg: "#282c34",
      panel: "#21252b",
      panelAlt: "#3a3f4b",
      border: "#3e4451",
      borderFocus: "#61afef",
      text: "#abb2bf",
      bright: "#ffffff",
      muted: "#9da5b4",
      dim: "#5c6370",
      accent: "#61afef",
      accent2: "#98c379",
      selectBg: "#3e4451",
      selectFg: "#ffffff",
      green: "#98c379",
      yellow: "#e5c07b",
      orange: "#d19a66",
      red: "#e06c75",
      cyan: "#56b6c2",
      magenta: "#c678dd"
    }
  },
  {
    id: "nord",
    label: "Nord（冷灰蓝）",
    palette: {
      bg: "#2e3440",
      panel: "#242a34",
      panelAlt: "#3f4859",
      border: "#4c566a",
      borderFocus: "#88c0d0",
      text: "#d8dee9",
      bright: "#eceff4",
      muted: "#aeb6c6",
      dim: "#616e88",
      accent: "#88c0d0",
      accent2: "#a3be8c",
      selectBg: "#434c5e",
      selectFg: "#eceff4",
      green: "#a3be8c",
      yellow: "#ebcb8b",
      orange: "#d08770",
      red: "#bf616a",
      cyan: "#8fbcbb",
      magenta: "#b48ead"
    }
  },
  {
    id: "gruvbox",
    label: "Gruvbox（暖棕）",
    palette: {
      bg: "#282828",
      panel: "#1d2021",
      panelAlt: "#32302f",
      border: "#504945",
      borderFocus: "#83a598",
      text: "#ebdbb2",
      bright: "#fbf1c7",
      muted: "#bdae93",
      dim: "#928374",
      accent: "#83a598",
      accent2: "#b8bb26",
      selectBg: "#504945",
      selectFg: "#fbf1c7",
      green: "#b8bb26",
      yellow: "#fabd2f",
      orange: "#fe8019",
      red: "#fb4934",
      cyan: "#8ec07c",
      magenta: "#d3869b"
    }
  },
  {
    id: "catppuccin",
    label: "Catppuccin（奶紫）",
    palette: {
      bg: "#1e1e2e",
      panel: "#181825",
      panelAlt: "#313244",
      border: "#45475a",
      borderFocus: "#89dceb",
      text: "#cdd6f4",
      bright: "#f5e0dc",
      muted: "#a6adc8",
      dim: "#6c7086",
      accent: "#89dceb",
      accent2: "#a6e3a1",
      selectBg: "#45475a",
      selectFg: "#cdd6f4",
      green: "#a6e3a1",
      yellow: "#f9e2af",
      orange: "#fab387",
      red: "#f38ba8",
      cyan: "#89dceb",
      magenta: "#cba6f7"
    }
  },
  {
    id: "dracula",
    label: "Dracula（紫粉）",
    palette: {
      bg: "#282a36",
      panel: "#21222c",
      panelAlt: "#343746",
      border: "#44475a",
      borderFocus: "#8be9fd",
      text: "#f8f8f2",
      bright: "#ffffff",
      muted: "#bfc7d5",
      dim: "#6272a4",
      accent: "#8be9fd",
      accent2: "#50fa7b",
      selectBg: "#44475a",
      selectFg: "#f8f8f2",
      green: "#50fa7b",
      yellow: "#f1fa8c",
      orange: "#ffb86c",
      red: "#ff5555",
      cyan: "#8be9fd",
      magenta: "#bd93f9"
    }
  },
  {
    id: "solarized",
    label: "Solarized（青蓝）",
    palette: {
      bg: "#002b36",
      panel: "#00252f",
      panelAlt: "#073642",
      border: "#586e75",
      borderFocus: "#268bd2",
      text: "#93a1a1",
      bright: "#eee8d5",
      muted: "#839496",
      dim: "#657b83",
      accent: "#268bd2",
      accent2: "#859900",
      selectBg: "#0b4a58",
      selectFg: "#eee8d5",
      green: "#859900",
      yellow: "#b58900",
      orange: "#cb4b16",
      red: "#dc322f",
      cyan: "#2aa198",
      magenta: "#6c71c4"
    }
  },
  {
    id: "monokai",
    label: "Monokai（高饱和）",
    palette: {
      bg: "#272822",
      panel: "#1e1f1c",
      panelAlt: "#3e3d32",
      border: "#49483e",
      borderFocus: "#66d9ef",
      text: "#f8f8f2",
      bright: "#ffffff",
      muted: "#cfcfc2",
      dim: "#75715e",
      accent: "#66d9ef",
      accent2: "#a6e22e",
      selectBg: "#49483e",
      selectFg: "#f8f8f2",
      green: "#a6e22e",
      yellow: "#e6db74",
      orange: "#fd971f",
      red: "#f92672",
      cyan: "#66d9ef",
      magenta: "#ae81ff"
    }
  },
  {
    id: "rosepine",
    label: "Rosé Pine（玫瑰）",
    palette: {
      bg: "#191724",
      panel: "#1f1d2e",
      panelAlt: "#26233a",
      border: "#403d52",
      borderFocus: "#c4a7e7",
      text: "#e0def4",
      bright: "#ffffff",
      muted: "#908caa",
      dim: "#6e6a86",
      accent: "#c4a7e7",
      accent2: "#9ccfd8",
      selectBg: "#403d52",
      selectFg: "#e0def4",
      green: "#9ccfd8",
      yellow: "#f6c177",
      orange: "#ebbcba",
      red: "#eb6f92",
      cyan: "#9ccfd8",
      magenta: "#c4a7e7"
    }
  },
  {
    id: "everforest",
    label: "Everforest（森绿）",
    palette: {
      bg: "#2d353b",
      panel: "#272e33",
      panelAlt: "#343f44",
      border: "#475258",
      borderFocus: "#9ec979",
      text: "#d3c6aa",
      bright: "#fff4e0",
      muted: "#9da9a0",
      dim: "#7a8478",
      accent: "#9ec979",
      accent2: "#83c092",
      selectBg: "#475258",
      selectFg: "#d3c6aa",
      green: "#a7c080",
      yellow: "#dbbc7f",
      orange: "#e69875",
      red: "#e67e80",
      cyan: "#83c092",
      magenta: "#d699b6"
    }
  }
];

export const DEFAULT_THEME = THEMES[0].id;

/** Live palette. Mutated in place by `applyTheme()`. */
export const PAL: Palette = { ...THEMES[0].palette };

let activeTheme = DEFAULT_THEME;
let activeBackground: string | undefined;

function toRgb(hex: string): [number, number, number] {
  const value = hex.replace("#", "");
  return [
    parseInt(value.slice(0, 2), 16),
    parseInt(value.slice(2, 4), 16),
    parseInt(value.slice(4, 6), 16)
  ];
}

function toHex(r: number, g: number, b: number): string {
  const clamp = (n: number) => Math.max(0, Math.min(255, Math.round(n)));
  return `#${[r, g, b].map((n) => clamp(n).toString(16).padStart(2, "0")).join("")}`;
}

function luminance(hex: string): number {
  const [r, g, b] = toRgb(hex);
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

/** Darken a color toward black; used to keep accents readable on light pages. */
function darken(hex: string, ratio: number): string {
  const [r, g, b] = toRgb(hex);
  return toHex(r * (1 - ratio), g * (1 - ratio), b * (1 - ratio));
}

function lighten(hex: string, ratio: number): string {
  const [r, g, b] = toRgb(hex);
  return toHex(r + (255 - r) * ratio, g + (255 - g) * ratio, b + (255 - b) * ratio);
}

/** Normalise a user supplied background color (`#1a1b26` or `1a1b26`). */
export function normalizeBackground(value: string | undefined): string | undefined {
  const text = String(value ?? "").trim();
  if (!text) return undefined;
  if (!/^#?[0-9a-f]{6}$/i.test(text)) return undefined;
  return (text.startsWith("#") ? text : `#${text}`).toLowerCase();
}

/**
 * Override the base background while keeping the palette's layered surfaces.
 * Light backgrounds also flip the text tones so the UI stays readable.
 *
 * Surface steps use fixed RGB offsets (not ratios) so very dark custom colors
 * still end up on different palette entries.
 */
function applyBackground(hex: string) {
  PAL.bg = hex;
  const shift = (delta: number) => {
    const [r, g, b] = toRgb(hex);
    return toHex(r + delta, g + delta, b + delta);
  };
  if (luminance(hex) > 0.6) {
    PAL.text = "#1f2430";
    PAL.bright = "#0b0f19";
    PAL.muted = "#374151";
    // Secondary text must stay legible on a light page: blessed quantises these
    // to the grey ramp, so darker values are needed than on a dark background.
    PAL.dim = "#4b5563";
    PAL.panel = shift(-8);
    PAL.panelAlt = shift(-20);
    // Selection must stay dark-on-light, otherwise `fg: bright` becomes
    // near-invisible dark text on the theme's dark blue selection bar.
    PAL.selectBg = lighten(PAL.accent, 0.62);
    PAL.selectFg = "#0b0f19";
    // Light accents are unreadable on a light page: darken the syntax set.
    PAL.accent = darken(PAL.accent, 0.35);
    PAL.borderFocus = PAL.accent;
    PAL.green = darken(PAL.green, 0.35);
    PAL.yellow = darken(PAL.yellow, 0.42);
    PAL.orange = darken(PAL.orange, 0.35);
    PAL.red = darken(PAL.red, 0.3);
    PAL.cyan = darken(PAL.cyan, 0.38);
    PAL.magenta = darken(PAL.magenta, 0.32);
  } else {
    PAL.panel = shift(-8);
    PAL.panelAlt = shift(16);
  }
}

export function themeIds(): string[] {
  return THEMES.map((theme) => theme.id);
}

export function getTheme(id: string | undefined): ThemeDef {
  return THEMES.find((theme) => theme.id === id) ?? THEMES[0];
}

export function activeThemeId(): string {
  return activeTheme;
}

export function activeBackgroundColor(): string | undefined {
  return activeBackground;
}

/**
 * Switch the palette in place. `background` overrides the theme background
 * color (empty / invalid = follow the theme). Returns true when the id was
 * recognised.
 */
export function applyTheme(id: string | undefined, background?: string): boolean {
  const theme = THEMES.find((item) => item.id === id);
  const chosen = theme ?? THEMES[0];
  Object.assign(PAL, chosen.palette);
  activeTheme = chosen.id;
  activeBackground = normalizeBackground(background);
  if (activeBackground) applyBackground(activeBackground);
  return Boolean(theme);
}
