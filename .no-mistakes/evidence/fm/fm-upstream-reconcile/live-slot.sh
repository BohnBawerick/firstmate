#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export TMPDIR=$ROOT/.test-phase-tmp
. "$ROOT/tests/lib.sh"
LAB=$ROOT/.test-phase-tmp/slot-manual
mkdir -p "$LAB/home"/{state,data,config} "$LAB/foreign-home" "$LAB/bin" "$LAB/pool/1" "$LAB/project"
export FM_HOME=$LAB/home
SOCKET=$ROOT/.test-phase-tmp/t.sock
cleanup() { /usr/bin/tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true; fm_test_cleanup; }
trap cleanup EXIT
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec /usr/bin/tmux -S "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"
git -C "$LAB/project" init -q --initial-branch=main
git -C "$LAB/project" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm 'Seed slot lab'
git -C "$LAB/project" worktree add -q --detach "$LAB/pool/1/project"
ln -s pool/1/project "$LAB/worktree"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$LAB/pool/1/project" > "$LAB/pool/treehouse-state.json"
printf 'foreign work must survive\n' > "$LAB/worktree/sentinel"
printf 'task=fix-api\nhome=%s\n' "$LAB/foreign-home" > "$LAB/pool/1/.fm-slot-owner"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'tmux\n' > "$FM_HOME/config/backend"
run tmux -f /dev/null new-session -d -s lab-a -n fm-fix-api -c "$LAB/home" 'sleep 180'
run tmux new-session -d -s lab-b -n fm-fix-api -c "$LAB/worktree" 'sleep 180'
worker=$(tmux display-message -p -t lab-b:fm-fix-api '#{pane_pid}')
cat > "$FM_HOME/state/fix-api.meta" <<EOF
window=lab-a:fm-fix-api
backend=tmux
endpoint_task_id=fix-api
worktree=$LAB/worktree
project=$LAB/project
kind=scout
EOF
run bin/fm-teardown.sh fix-api --force
run tmux list-panes -a -F '#{session_name}:#{window_name} pid=#{pane_pid} command=#{pane_current_command}'
kill -0 "$worker"
run cat "$LAB/worktree/sentinel"
run cat "$LAB/pool/1/.fm-slot-owner"
[ ! -e "$FM_HOME/state/fix-api.meta" ]
printf 'Stale home record retired; the foreign worker, worktree, and ownership claim survived.\n'
