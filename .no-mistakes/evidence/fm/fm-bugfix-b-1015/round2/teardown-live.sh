#!/usr/bin/env bash
# Behavior tests for bin/fm-live-lab.sh (readiness checks and teardown) and
# bin/fm-claude-trust.sh --lab-home.
#
# Every readiness check is proven both ways against a real private tmux server
# and real processes, with no harness: it passes on a lab in the shape up builds
# and fails, by name, on the recorded lab miss it exists to catch. The live
# end-to-end run on the real harnesses is the builder's own `up`.
set -u

# shellcheck source=tests/fixtures.sh
. "$PWD/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-lab)
: > "$TMP_ROOT/pids"
: > "$TMP_ROOT/tmux-dirs"
LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
TRUST="$ROOT/bin/fm-claude-trust.sh"

live_lab_cleanup() {
  local dir pid marker
  for marker in "$TMP_ROOT/orphan-child" "$TMP_ROOT/late-child" "$TMP_ROOT/reused-child"; do
    [ ! -s "$marker" ] || printf '%s\n' "$(<"$marker")" >> "$TMP_ROOT/pids"
  done
  while read -r pid; do [ -n "$pid" ] && { pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; }; done < "$TMP_ROOT/pids"
  while read -r dir; do
    [ -n "$dir" ] || continue
    env -u TMUX TMUX_TMPDIR="$dir" tmux kill-server 2>/dev/null
    case "$dir" in /tmp/fml.*) rm -rf "$dir" ;; esac
  done < "$TMP_ROOT/tmux-dirs"
  rm -rf "/tmp/fm-labt$$-mate" "/tmp/fm-labt$$-worker" "/tmp/fm-labt$$-other" /tmp/fm-labt"$$"-*+*
  fm_test_cleanup
}
trap live_lab_cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "ok - skipped: tmux is not installed"; exit 0; }

FAKE_HOME="$TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME/.pi/agent" "$FAKE_HOME/.treehouse/existing-pool"
printf '{}\n' > "$FAKE_HOME/.pi/agent/trust.json"
export HOME="$FAKE_HOME"
unset CLAUDE_CONFIG_DIR TMUX

MATE_ID="labt$$-mate"
WORKER_ID="labt$$-worker"
NONCE=abc12345

digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    sha256sum "$1"
  fi | awk '{print $1}'
}

# make_lab <name> <harness> [<claude-config-dir>]: a lab root in the shape up
# builds, with a live private tmux server. Every readiness input starts in its
# passing state.
make_lab() {
  local root="$TMP_ROOT/$1" harness=$2 claude_dir=${3:-} home tmux_dir lock_pid
  home="$root/home"
  mkdir -p "$root"
  "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null || fail "lab home create"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  mkdir -p "$home/.pi" "$home/data/$WORKER_ID" "$root/mate/state" "$root/treehouse"
  cp -R "$ROOT/.pi/extensions" "$home/.pi/extensions"
  git -C "$home" init -q -b main
  git -C "$home" add -A bin AGENTS.md .pi
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm lab
  tmux_dir=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$home") || fail "lab tmux dir"
  printf '%s\n' "$tmux_dir" >> "$TMP_ROOT/tmux-dirs"
  find "$HOME/.treehouse" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > "$root/.treehouse-before"
  {
    echo 'fm-live-lab v1'
    echo "harness=$harness"
    echo "home=$home"
    echo "expect_host=yes"
    echo "host_off=no"
    echo "mate=yes"
    echo "worker=yes"
    echo "nonce=$NONCE"
    echo "mate_id=$MATE_ID"
    echo "worker_id=$WORKER_ID"
    echo "gate=$home/data/$WORKER_ID/gate"
    echo "pi_trust=$(digest "$HOME/.pi/agent/trust.json")"
    echo "claude_config_dir=$claude_dir"
    echo "claude_store=${claude_dir:-$HOME}/.claude.json"
    echo "pi_trust_store=$HOME/.pi/agent/trust.json"
    echo "treehouse_dir=$HOME/.treehouse"
    echo "tmux_dir=$tmux_dir"
  } > "$root/.fm-live-lab"

  lab_tmux "$root" new-session -d -s firstmate -n lab -c "$root" 'exec sleep 600'
  record_pid "$root" "$(lab_tmux "$root" display-message -p '#{pid}')"
  lab_tmux "$root" new-window -d -t firstmate: -n main -c "$home" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$root/mate" 'exec sleep 600'
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$WORKER_ID" -c "$root" 'exec sleep 600'
  fm_write_meta "$home/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID" "tasktmp=/tmp/fm-$MATE_ID"
  fm_write_meta "$home/state/$WORKER_ID.meta" "window=firstmate:fm-$WORKER_ID" "worktree=$home/projects/notes" "kind=secondmate" "tasktmp=/tmp/fm-$WORKER_ID"
  mkdir -p "$home/projects/notes"
  printf 'paused [at=1]: waiting on gate file %s to exist\n' "$home/data/$WORKER_ID/gate" > "$home/state/$WORKER_ID.status"

  lock_pid=$(lab_tmux "$root" display-message -p -t firstmate:=main '#{pane_pid}')
  printf '%s\n' "$lock_pid" > "$home/state/.lock"
  printf '%s\n' "$(lab_tmux "$root" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}')" > "$root/mate/state/.lock"
  start_watcher "$home"
  printf 'host\t%s\tx\n' "$(start_sleeper)" > "$home/state/.supervision-host"
  printf '%s\n' \
    '{"seq":1,"epoch":1,"key":"k","id":"a","tag":"captain","text":"probe"}' \
    '{"seq":2,"epoch":2,"key":"k","id":"b","tag":"main","text":"LABREADY"}' > "$home/state/.host-mirror.jsonl"
  write_pi_markers "$home" "$lock_pid"
  [ "$harness" = claude ] && node -e 'const fs=require("node:fs");const [s,h,r]=process.argv.slice(1);fs.writeFileSync(s,JSON.stringify({keep:1,projects:{[h]:{hasTrustDialogAccepted:true},[r+"/mate"]:{hasTrustDialogAccepted:true},"/elsewhere/project":{hasTrustDialogAccepted:true}}},null,2)+"\n")' \
    "${claude_dir:-$HOME}/.claude.json" "$home" "$root"
  printf '%s\n' "$root"
}

# Recorded fixture roots must not share the runner's process group.
start_group() { perl -e 'setpgrp(0,0); exec @ARGV' "$@" >/dev/null 2>&1 & }

record_pid() {  # <root> <pid>
  printf 'launch_pid=%s\nlaunch_start=%s\n' "$2" "$(ps -o lstart= -p "$2" | awk '{$1=$1; print}')" >> "$1/.fm-live-lab"
}

lab_tmux() {  # <root> <tmux args...>
  local dir
  dir=$(sed -n 's/^tmux_dir=//p' "$1/.fm-live-lab")
  shift
  env -u TMUX TMUX_TMPDIR="$dir" tmux "$@"
}

start_sleeper() {
  sleep 600 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/pids"
  printf '%s\n' "$!"
}

start_watcher() {  # <home>: a live process holding a matching watcher lock
  local home=$1 pid lock="$1/state/.watch.lock"
  pid=$(start_sleeper)
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$lock/watcher-path"
  fm_test_pid_identity "$pid" > "$lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

write_pi_markers() {  # <home> <lock-pid>
  local home=$1 pid=$2
  v() { FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pi_extension_version "$1/.pi/extensions/$2"' _ "$home" "$1"; }
  printf '%s\n%s\ngeneration=1 phase=active\n' "$(v fm-primary-pi-watch.ts)" "$pid" > "$home/state/.pi-watch-extension-loaded"
  printf '%s\n%s\n' "$(v fm-primary-turnend-guard.ts)" "$pid" > "$home/state/.pi-turnend-extension-loaded"
  printf '%s\n' "$pid" > "$home/state/.pi-branch-extension-loaded"
}

run_check() {  # <root>: sets CHECK_OUT and CHECK_RC
  CHECK_OUT=$("$LIVE_LAB" check "$1" 2>&1)
  CHECK_RC=$?
}

set_record() {  # <root> <key> <value>
  sed -i.bak "s|^$2=.*|$2=$3|" "$1/.fm-live-lab" && rm -f "$1/.fm-live-lab.bak"
}

# A process scan can miss both an exiting root and its TERM-spawned child.
LATE=$(make_lab late claude)
cat > "$TMP_ROOT/late-rewriter.sh" <<'SH'
store=$1 key=$2 marker=$3
trap 'bash -c '\''sleep 3; node -e "const fs=require(\"node:fs\");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,\"utf8\"));j.projects[k]={hasTrustDialogAccepted:true};fs.writeFileSync(s,JSON.stringify(j))" "$1" "$2"'\'' _ "$store" "$key" >/dev/null 2>&1 & echo $! > "$marker"; exit 0' TERM
echo ready > "$marker.ready"
while :; do sleep 0.1; done
SH
start_group bash "$TMP_ROOT/late-rewriter.sh" "$HOME/.claude.json" "$LATE/home" "$TMP_ROOT/late-child"
LATE_ROOT=$!
printf '%s\n' "$LATE_ROOT" >> "$TMP_ROOT/pids"
for ((attempt=0; attempt<50; attempt++)); do
  [ -s "$TMP_ROOT/late-child.ready" ] && break
  sleep 0.1
done
assert_present "$TMP_ROOT/late-child.ready" "TERM fixture installed its handler before down"
record_pid "$LATE" "$LATE_ROOT"
mkdir -p "$TMP_ROOT/late-ps-bin"
cat > "$TMP_ROOT/late-ps-bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ] && [ "${2:-}" = 'pid=,ppid=,pgid=,stat=,lstart=' ]; then
  count=$(cat "$PS_SCAN_COUNT" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$PS_SCAN_COUNT"
  if [ "$count" -eq 2 ]; then
    kill -0 -- "-$PS_GROUP" 2>/dev/null && touch "$PS_SCAN_COUNT.missed"
  fi
  "$REAL_PS" "$@" | awk -v scan="$count" -v group="$PS_GROUP" '
    scan == 2 && $3 == group { next }
    { print }
  '
else
  "$REAL_PS" "$@"
fi
SH
chmod +x "$TMP_ROOT/late-ps-bin/ps"
out=$(REAL_PS="$(command -v ps)" PS_SCAN_COUNT="$TMP_ROOT/late-scan-count" PS_GROUP="$LATE_ROOT" PATH="$TMP_ROOT/late-ps-bin:$PATH" "$LIVE_LAB" down "$LATE" 2>&1)
rc=$?
printf '%s\n' "$out"
printf 'down exit=%s\n' "$rc"
expect_code 0 "$rc" "down waits for a child born during TERM: $out"
assert_present "$TMP_ROOT/late-scan-count.missed" "the missed scan hid a group that still existed"
assert_present "$TMP_ROOT/late-child" "TERM handler spawned a child"
LATE_CHILD=$(cat "$TMP_ROOT/late-child")
printf '%s\n' "$LATE_CHILD" >> "$TMP_ROOT/pids"
sleep 3.5
case "$(ps -o stat= -p "$LATE_CHILD" 2>/dev/null | awk '{$1=$1; print}')" in ''|Z*) ;; *) fail "down leaves a TERM-spawned child alive" ;; esac
lab_keys=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(j.projects).filter(k=>k.startsWith(process.argv[2])).join(" "))' "$HOME/.claude.json" "$LATE")
assert_equals "" "$lab_keys" "TERM-spawned child cannot re-add trust after down"
pass "down tracks TERM-spawned descendants across a missed process scan"


printf 'TERM root pid=%s child pid=%s\n' "$LATE_ROOT" "$LATE_CHILD"
printf 'Child process after delayed write window: '
ps -o pid=,stat=,args= -p "$LATE_CHILD" || true
printf 'Remaining lab trust keys: <%s>\n' "$lab_keys"
printf 'Missed scan proof: '; cat "$TMP_ROOT/late-scan-count"; test -f "$TMP_ROOT/late-scan-count.missed"
