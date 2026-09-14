#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/watch-manual
mkdir -p "$LAB/home"/{state,data,config} "$LAB/bin"
export FM_HOME=$LAB/home TMPDIR=$ROOT/.test-phase-tmp FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
cleanup() { bin/fm-procevent.sh sweep-home >/dev/null 2>&1 || true; }
trap cleanup EXIT
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
cat > "$LAB/bin/action" <<'SH'
#!/usr/bin/env bash
printf 'executed\n' >> "$1"
printf 'action completed\n'
SH
chmod +x "$LAB/bin/action"
run bin/fm-procevent-when.sh arm updated-action --interval 0.1 --stable 2 --condition test -f "$LAB/ready" --action "$LAB/bin/action" "$LAB/action.log"
printf 'printf "updated action version\\n"\n' >> "$LAB/bin/action"
run bin/fm-procevent-when.sh rebind-all
run bin/fm-procevent.sh reconcile
run bin/fm-procevent.sh list
[ ! -e "$LAB/action.log" ]
printf 'Action has not fired before the condition.\n'
touch "$LAB/ready"
for _ in $(seq 1 100); do
  compgen -G "$FM_HOME/state/procevent-inbox/when-updated-action.*.result" >/dev/null && break
  sleep 0.1
done
result=$(find "$FM_HOME/state/procevent-inbox" -name 'when-updated-action.*.result' | head -1)
[ -n "$result" ]
run cat "$result"
[ "$(bin/fm-procevent-when.sh classify "$result")" = fired ]
run bin/fm-procevent.sh reconcile
[ "$(wc -l < "$LAB/action.log")" -eq 1 ]
printf 'Exactly one action invocation after reconcile.\n'
run cat "$FM_HOME/state/.wake-queue"
run bin/fm-procevent-when.sh arm tampered-action --interval 0.1 --stable 1 --condition true --action "$LAB/bin/action" "$LAB/tampered.log"
printf 'printf "unapproved replacement\\n"\n' >> "$LAB/bin/action"
run bin/fm-procevent.sh reconcile
for _ in $(seq 1 100); do
  compgen -G "$FM_HOME/state/procevent-inbox/when-tampered-action.*.result" >/dev/null && break
  sleep 0.1
done
result=$(find "$FM_HOME/state/procevent-inbox" -name 'when-tampered-action.*.result' | head -1)
run cat "$result"
[ "$(bin/fm-procevent-when.sh classify "$result")" = rejected ]
[ ! -e "$LAB/tampered.log" ]
printf 'Unbound action mutation rejected without execution.\n'
