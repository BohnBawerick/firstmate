import { existsSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

// The worker launcher supplies this marker before starting its private server.
// Bare primary launches still need an explicit v2 refusal.
const v2 = process.env.FM_OPENCODE_V2_WORKER === "1" ||
  /^(?:opencode\s+)?v?2\./.test(spawnSync("opencode", ["--version"], { encoding: "utf8" }).stdout?.trim() ?? "");

// V2 loads these files in worker worktrees too, but cannot run the v1 hooks.
export function v2WorkerOnly(id) {
  // Older v1 loaders call every export; v2 requires an object definition.
  if (!v2) return async () => ({});
  return {
    id,
    setup(ctx) {
      if (!existsSync(join(ctx.location.directory, ".opencode/plugins/fm-busy-state.js"))) {
        throw new Error("Firstmate OpenCode v2 primary supervision is not supported; use a verified primary harness. V2 supports spawned workers only.");
      }
    },
  };
}
