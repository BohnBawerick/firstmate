#!/usr/bin/env bash
# OpenCode busy plugin generator shared by spawn and the live adapter guard.
# fm_opencode_write_busy_plugin <destination> <major> <code-root> <state-dir>
# <id> <generation> <turnend> <notify:true|false>
fm_opencode_write_busy_plugin() {
  local destination=$1 OPENCODE_MAJOR=$2 FM_ROOT=$3 STATE_REAL=$4 ID=$5 BUSY_GEN=$6 TURNEND=$7 busy_notify_turnend=$8
    if [ "$OPENCODE_MAJOR" -ge 2 ]; then
      cat >"$destination" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode 2's session.execution.started and terminal
// session.execution.* events, with the OpenCode 1 session.status/session.idle
// names retained as legacy inputs. Scoping latches the first session that
// reports activity and ignores other sessions until the latched session settles,
// so a child's terminal event can never clear the worker's busy state. The
// turn-ended touch stays the watcher's wake NOTIFICATION, never current-state
// truth.
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
const touchTurnEnded = () =>
  new Promise((resolve) => {
    execFile("touch", ["$TURNEND"], () => resolve());
  });
const eventType = (event) => event && (event.type || event.name) || "";
const eventProperties = (event) => event && (event.properties || event.data) || {};
const sessionID = (event) => {
  const properties = eventProperties(event);
  return properties.sessionID || properties.sessionId || (properties.session && properties.session.id) || properties.id || "";
};
const setupEventSubscription = (ctx, handler) => {
  if (!ctx || !ctx.event || !ctx.event.subscribe) return false;
  const controller = new AbortController();
  void (async () => {
    try {
      const stream = await ctx.event.subscribe({ signal: controller.signal, onActivity() {} });
      for await (const event of stream) await handler(event);
      if (!controller.signal.aborted) throw new Error("OpenCode event stream closed");
    } catch (error) {
      if (!controller.signal.aborted) {
        await busyEvent("unknown", "event-stream-failed");
        console.error("Firstmate OpenCode busy event stream failed", error);
      }
    }
  })();
  return () => controller.abort();
};
const makeHandler = (ctx) => {
  const workerSession = process.env.FM_OPENCODE_SESSION;
  const owns = async (id) => {
    if (!ctx) return true;
    if (workerSession) return id === workerSession;
    const result = await ctx.session.get({ sessionID: id });
    const session = result.data ?? result;
    const directory = ctx.location?.project?.directory;
    return typeof directory === "string" && directory.length > 0 && !session.parentID && session.location?.directory === directory;
  };
  let activeSession = null;
  return async (event) => {
    const type = eventType(event);
    const id = sessionID(event);
    if (type === "session.execution.started") {
      if (activeSession === null && id && await owns(id)) activeSession = id;
      if (id === activeSession) await busyEvent("busy", "session-execution-started");
      return;
    }
    if (type === "session.execution.succeeded" || type === "session.execution.interrupted" || type === "session.execution.failed") {
      if (id === activeSession) {
        activeSession = null;
        await busyEvent("idle", type.replace(/\./g, "-"), !!ctx && notifyTurnEnd);
      }
      if (!ctx && notifyTurnEnd) await touchTurnEnded();
      return;
    }
    if (type === "session.status") {
      const properties = eventProperties(event);
      const statusType = properties.status && properties.status.type;
      if (statusType === "busy" || statusType === "retry") {
        if (activeSession === null && id && await owns(id)) activeSession = id;
        if (id === activeSession) await busyEvent("busy", "session-" + statusType);
        return;
      }
      if (statusType === "idle" && id === activeSession) {
        activeSession = null;
        await busyEvent("idle", "session-status-idle");
      }
      return;
    }
    if (type === "session.idle") {
      if (id === activeSession) {
        activeSession = null;
        await busyEvent("idle", "session-idle", !!ctx && notifyTurnEnd);
      }
      if (!ctx && notifyTurnEnd) await touchTurnEnded();
    }
  };
};
export const FmBusyState = async () => {
  const handleEvent = makeHandler();
  return {
    event: async ({ event }) => handleEvent(event),
  };
};

export default {
  id: "fm.busy-state",
  server: FmBusyState,
  setup(ctx) {
    return setupEventSubscription(ctx, makeHandler(ctx));
  },
};
EOF
    else
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
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
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
    fi
}
