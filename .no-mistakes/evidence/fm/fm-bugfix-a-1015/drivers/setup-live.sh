#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D="$ROOT/.nm-live-test/live"
mkdir -p "$D/bin" "$D/project/.claude"
export TMPDIR="$ROOT/.nm-live-test/tmp"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.nm-live-test/herdr-state"
SESSION=$(bin/fm-herdr-lab.sh name bundle-a)
LAB=$(mktemp -d "$D/home.XXXXXX")
bin/fm-lab-home.sh create "$LAB"
printf -v ROOT_Q '%q' "$ROOT"
printf -v LAB_Q '%q' "$LAB"
printf -v SESSION_Q '%q' "$SESSION"
cat > "$D/env.sh" <<EOF
export ROOT=$ROOT_Q
export FM_HOME=$LAB_Q
export HERDR_SESSION=$SESSION_Q
export FM_HERDR_LAB_STATE_DIR="$ROOT/.nm-live-test/herdr-state"
export TREEHOUSE_ROOT="$D/pool"
export TMPDIR="$ROOT/.nm-live-test/tmp"
export PATH="$D/bin:\$PATH"
export REAL_HERDR="$(command -v herdr)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX CLAUDE_PID CLAUDE_CODE_SESSION_ID TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
EOF
cat > "$D/bin/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if (( n >= 2 )) && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$HERDR_SESSION" ]; then
  unset 'args[n-1]' 'args[n-2]'
fi
if [ "${args[0]}" = --version ]; then
  exec "$REAL_HERDR" "${args[@]}" --session "$HERDR_SESSION"
fi
PATH=${PATH#*:} exec "$ROOT/bin/fm-herdr-lab.sh" run "$HERDR_SESSION" "${args[@]}"
WRAPPER
chmod +x "$D/bin/herdr"
. "$D/env.sh"
PATH=${PATH#*:} "$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION"
git -C "$D/project" init -q -b main
printf '# Disposable validation project\n' > "$D/project/README.md"
printf '{"env":{"FM_LAB_KEEP":"original"},"includeCoAuthoredBy":false}\n' > "$D/project/.claude/settings.local.json"
git -C "$D/project" add .
git -C "$D/project" -c user.name='Validation' -c user.email='validation@example.invalid' commit -qm initial
git clone -q --bare "$D/project" "$D/origin.git"
git -C "$D/project" remote add origin "$D/origin.git"
for id in coder clauder missing; do
  bin/fm-brief.sh "$id" validation --scout --herdr-lab >/dev/null
  python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'This is a disposable launch check. Do not edit any files or run any tools. Reply ready and wait.').replace('{FIRSTMATE_SPEC}', 'Wait for further instructions. Do not do work.')
open(p,'w').write(s)
PY
done
printf 'Lab session: %s\nHome: %s\n' "$SESSION" "$FM_HOME"
PATH=${PATH#*:} bin/fm-herdr-lab.sh run "$SESSION" workspace list
