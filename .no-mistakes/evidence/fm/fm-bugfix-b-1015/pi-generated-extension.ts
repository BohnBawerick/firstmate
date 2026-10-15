// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
import { appendFileSync } from "node:fs";
const notifyTurnEnd = false;
const excludeTools = "".split(",").filter(Boolean);
const excludeFile = "/tmp/fm-secondmate-busy-live.dPSdPz/pi/primary/config/crew-exclude-tools";
const statusFile = "/tmp/fm-secondmate-busy-live.dPSdPz/pi/primary/state/sm-pi.status";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M50CWGPF8YPNBTQRHJHZRNM6/bin/fm-busy-event.sh", [
      "apply", "/tmp/fm-secondmate-busy-live.dPSdPz/pi/primary/state", "sm-pi", state,
      "--gen", "g1792092706.3249564.3934", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  let checkedExclusions = false;
  pi.on("agent_start", async () => {
    await busyEvent("busy", "agent-start");
    // Verify only this worker's registry, never connect servers from Firstmate.
    // Check before actions so the warning cannot supersede this turn's terminal status.
    if (!checkedExclusions && excludeTools.length) {
      const loaded = new Set(pi.getAllTools().map((tool: any) => tool.name));
      const unmatched = excludeTools.filter((name) => !loaded.has(name));
      if (unmatched.length) {
        appendFileSync(statusFile, "note [at=" + Math.floor(Date.now() / 1000) + "]: warning: " + excludeFile
          + " unmatched exclusion entries (unverified: absent from the worker's loaded-tool registry; excluded tools or unavailable servers cannot be verified): "
          + unmatched.join(", ") + "\n");
      }
      checkedExclusions = true;
    }
  });
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => { if (notifyTurnEnd) execFile("touch", ["/tmp/fm-secondmate-busy-live.dPSdPz/pi/primary/state/sm-pi.turn-ended"]); });
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M50CWGPF8YPNBTQRHJHZRNM6/bin/fm-busy-event.sh", [
      "progress", "/tmp/fm-secondmate-busy-live.dPSdPz/pi/primary/state", "sm-pi", "--gen", "g1792092706.3249564.3934",
    ]);
  });
}
