// Mirror of Swift OhhExporter.SnorohFile (same JSON format for both
// .snoroh and .animime — the extension is just branding).
export const STATUSES = [
  "initializing",
  "searching",
  "idle",
  "busy",
  "service",
  "disconnected",
  "visiting",
] as const;

export type StatusKey = (typeof STATUSES)[number];

export interface SpriteEntry {
  frames: number;
  data: string; // base64 PNG
}

export interface SnorohFile {
  version: number;
  name: string;
  sprites: Record<string, SpriteEntry>;
}
