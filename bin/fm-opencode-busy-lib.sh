#!/usr/bin/env bash
# OpenCode busy plugin generator shared by spawn and the live adapter guard.
# Source this file, then call fm_opencode_write_busy_plugin <destination>
# <major:1|2> <code-root> <state-dir> <id> <generation> <turnend> <notify:true|false>.

fm_opencode_write_busy_plugin() {
  local destination=$1 major=$2 FM_ROOT=$3 STATE_REAL=$4 ID=$5 BUSY_GEN=$6 TURNEND=$7 busy_notify_turnend=$8
  cat >"$destination" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode's session.status events: busy and retry
// are active, idle is inactive. Scoping latches the first session that
// reports activity (the worker's main session - a subagent child session can
// only start while the main session is already busy) and ignores other
// sessions' status until the latched session settles, so a child's idle can
// never clear the worker's busy state. The session.idle touch stays the
// watcher's wake NOTIFICATION, never current-state truth.
import { execFile } from "node:child_process";
const notifyTurnEnd = $busy_notify_turnend;
const busyEvent = (state, event, turnEnded = false) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
      ...(turnEnded ? ["--turn-ended"] : []),
    ], () => resolve());
  });
export const FmBusyState = async () => {
  let activeSession = null;
  return {
    event: async ({ event }) => {
      if (event.type === "session.status") {
        const sessionID = event.properties.sessionID;
        const statusType = event.properties.status && event.properties.status.type;
        if (statusType === "busy" || statusType === "retry") {
          if (activeSession === null) activeSession = sessionID;
          if (sessionID === activeSession) await busyEvent("busy", "session-" + statusType);
          return;
        }
        if (statusType === "idle" && sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-status-idle");
        }
        return;
      }
      if (event.type === "session.idle") {
        if (event.properties.sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-idle");
        }
        if (notifyTurnEnd) {
          await new Promise((resolve) => {
            execFile("touch", ["$TURNEND"], () => resolve());
          });
        }
      }
    },
  };
};
EOF
  [ "$major" = 2 ] || return 0
  cat >>"$destination" <<'EOF'

// V2's private server inherits the exact session selected by the launcher.
export default {
  id: "firstmate.busy",
  async setup(ctx) {
    const workerSession = process.env.FM_OPENCODE_SESSION;
    const controller = new AbortController();
    let activeSession = null;
    const owns = async (sessionID) => {
      if (workerSession) return sessionID === workerSession;
      // Native --continue has no launch binding; its private server still
      // admits only a top-level session in this worker's exact directory.
      const result = await ctx.session.get({ sessionID });
      const session = result.data ?? result;
      return !session.parentID && session.location?.directory === ctx.location.directory;
    };
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        const sessionID = event.data?.sessionID;
        if (!sessionID || !event.type.startsWith("session.execution.")) continue;
        if (event.type === "session.execution.started") {
          if (activeSession === null && await owns(sessionID)) activeSession = sessionID;
          if (sessionID === activeSession) await busyEvent("busy", "execution-started");
        } else if (["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].includes(event.type) && sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", event.type.slice("session.".length), notifyTurnEnd);
        }
      }
      if (!controller.signal.aborted) throw new Error("OpenCode event stream closed");
    })().catch(async (error) => {
      if (!controller.signal.aborted) {
        await busyEvent("unknown", "event-stream-failed");
        console.error("Firstmate OpenCode v2 busy event stream failed", error);
      }
    });
    return () => controller.abort();
  },
};
EOF
}
