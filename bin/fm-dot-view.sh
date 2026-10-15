#!/usr/bin/env bash
# fm-dot-view.sh - reconcile read-only dot displays, never cloud execution.
# Usage: FM_HOME=<parent> fm-dot-view.sh sync|watch <mate-id> <herdr-session>
# sync makes one bounded pass; watch repeats every five seconds. Stop watch with
# SIGTERM; it leaves displays and all cloud work alone. After restart, use
# fm-send.sh <mate-id> to request native child reconciliation from the dot.
# Bindings live separately under state/dot-views. Unknown IDs, renamed tabs,
# ambiguous creates and incomplete inventories refuse cleanup. No process spawn,
# worktree allocation, session lifecycle or fleet presentation setting is used.
set -euo pipefail
case "${1:-}" in --help|-h)
  printf 'Usage: FM_HOME=<parent> fm-dot-view.sh sync|watch <mate-id> <herdr-session>\n'
  exit 0 ;;
esac
[ "$#" -eq 3 ] || { echo 'error: expected sync|watch, mate id and explicit Herdr session' >&2; exit 1; }
COMMAND=$1 ID=$2 SESSION=$3
case "$COMMAND" in sync|watch) ;; *) exit 1 ;; esac
case "$ID:$SESSION" in *[!A-Za-z0-9._:-]*|:*) exit 1 ;; esac
[ -n "$SESSION" ] && [ -n "${FM_HOME:-}" ] || exit 1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=$(cd "$FM_HOME" && pwd -P)
export FM_HOME HERDR_SESSION=$SESSION
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/backends/herdr.sh
. "$SCRIPT_DIR/backends/herdr.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fail() { printf 'fm-dot-view: %s\n' "$*" >&2; exit 1; }
"$SCRIPT_DIR/fm-dot-secondmate.sh" validate "$ID"
DB=$(fm_meta_get "$FM_HOME/state/$ID.meta" dot_mailbox_db)
DIR="$FM_HOME/state/dot-views"
[ ! -L "$DIR" ] || fail 'unsafe display directory'
(umask 077; mkdir -p "$DIR")
BINDING="$DIR/$ID.json"
LOCK='' SNAPSHOT=''
cleanup() {
  [ -z "$LOCK" ] || fm_lock_release "$LOCK"
  [ -z "$SNAPSHOT" ] || rm -f "$SNAPSHOT"
  return 0
}
trap cleanup EXIT
trap 'exit 0' TERM INT

save() {
  local tmp
  tmp=$(umask 077; mktemp "$DIR/.binding.XXXXXX")
  printf '%s\n' "$RECORD" > "$tmp"
  mv "$tmp" "$BINDING"
}

launch_reader() { # <pane> <child-or-console>
  local pane=$1 child=$2 command
  printf -v command 'exec env FM_HOME=%q python3 %q --db %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-dot-view.py" "$DB" "$ID"
  if [ "$child" != console ]; then
    printf -v command '%s --child %q' "$command" "$child"
  fi
  fm_backend_herdr_cli "$SESSION" pane run "$pane" "$command" >/dev/null
}

matches() { # <tab> <pane> <label>
  local tab=$1 pane=$2 label=$3 tabs panes
  tabs=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WS") || return 1
  panes=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$WS") || return 1
  jq -e --arg t "$tab" --arg l "$label" '[.result.tabs[] | select(.tab_id==$t and .label==$l)] | length==1' <<< "$tabs" >/dev/null &&
    jq -e --arg p "$pane" --arg t "$tab" '[.result.panes[] | select(.pane_id==$p and .tab_id==$t)] | length==1' <<< "$panes" >/dev/null
}

sync_view() {
  local lock record_home record_session presence label info child tab pane focus pair row
  "$SCRIPT_DIR/fm-dot-secondmate.sh" validate "$ID"
  SNAPSHOT=$(umask 077; mktemp "$DIR/.snapshot.XXXXXX")
  "$SCRIPT_DIR/fm-dot-secondmate.sh" snapshot "$ID" > "$SNAPSHOT"
  jq -e '.children_truncated == false' "$SNAPSHOT" >/dev/null || fail 'child inventory truncated; refusing display reconciliation'
  lock=$(fm_backend_herdr_presentation_session_lock_path "$SESSION") || fail 'no safe presentation lock'
  fm_lock_try_acquire "$lock" || fail 'presentation lock busy; retry sync'
  LOCK=$lock
  if [ -e "$BINDING" ]; then
    [ ! -L "$BINDING" ] || fail 'unsafe display binding'
    RECORD=$(<"$BINDING")
    record_home=$(jq -r '.home' <<< "$RECORD")
    record_session=$(jq -r '.session' <<< "$RECORD")
    [ "$record_home" = "$FM_HOME" ] && [ "$record_session" = "$SESSION" ] || fail 'display binding belongs to another home or session'
    jq -e '.pending == false' <<< "$RECORD" >/dev/null || fail 'ambiguous earlier display create; inspect recorded binding before retry'
    WS=$(jq -r '.workspace' <<< "$RECORD")
    presence=$(fm_backend_herdr_workspace_presence_state "$SESSION" "$WS")
    case "$presence" in
      dead) RECORD='' ;;
      present)
        info=$(fm_backend_herdr_cli "$SESSION" workspace get "$WS")
        jq -e --arg label "2ndmate-$ID" '.result.workspace.label==$label' <<< "$info" >/dev/null || fail 'display workspace was renamed'
        ;;
      *) fail 'display workspace presence unknown' ;;
    esac
  else
    RECORD=''
  fi
  if [ -z "$RECORD" ]; then
    TOKEN=$(fm_backend_herdr_projection_id)
    label="mate-$ID-$TOKEN"
    RECORD=$(jq -n --arg home "$FM_HOME" --arg session "$SESSION" --arg token "$TOKEN" '{home:$home,session:$session,token:$token,pending:true,displays:{}}')
    save
    fm_backend_herdr_projection_create_task "$FM_HOME" "2ndmate-$ID" "$label" existing-session-only || fail 'display create was not confirmed; binding retained'
    WS=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
    tab=$FM_BACKEND_HERDR_PROJECTION_TAB_ID pane=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
    RECORD=$(jq --arg ws "$WS" --arg t "$tab" --arg p "$pane" --arg l "$label" '.workspace=$ws | .pending=false | .displays.console={tab:$t,pane:$p,label:$l}' <<< "$RECORD")
    save
    launch_reader "$pane" console
  fi
  TOKEN=$(jq -r '.token' <<< "$RECORD")
  while IFS= read -r row; do
    child=$(jq -r '.key' <<< "$row")
    tab=$(jq -r '.value.tab' <<< "$row")
    pane=$(jq -r '.value.pane' <<< "$row")
    label=$(jq -r '.value.label' <<< "$row")
    if ! matches "$tab" "$pane" "$label"; then
      presence=$(fm_backend_herdr_pane_presence_state "$SESSION" "$pane")
      [ "$presence" = dead ] || fail 'display ownership changed; no mutation allowed'
      RECORD=$(jq --arg c "$child" 'del(.displays[$c])' <<< "$RECORD")
      save
      continue
    fi
    if [ "$child" != console ] && jq -e --arg c "$child" 'any(.children[]; .id==$c and .terminal and .parent_delivered)' "$SNAPSHOT" >/dev/null; then
      fm_backend_herdr_projection_close_pane_focus_preserving "$SESSION" "$pane" || fail 'display close refused'
      [ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$pane")" = dead ] || fail 'display close not confirmed'
      RECORD=$(jq --arg c "$child" 'del(.displays[$c])' <<< "$RECORD")
      save
    fi
  done < <(jq -c '.displays | to_entries[]' <<< "$RECORD")
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    if jq -e --arg c "$child" '.displays[$c] != null' <<< "$RECORD" >/dev/null; then continue; fi
    label="$child-$TOKEN"
    # A unique label is not authority to reclaim a tab after an ambiguous create.
    info=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WS")
    jq -e --arg l "$label" 'all(.result.tabs[]; .label!=$l)' <<< "$info" >/dev/null || fail 'unbound display label already exists'
    RECORD=$(jq '.pending=true' <<< "$RECORD")
    save
    focus=$(fm_backend_herdr_projection_focus_snapshot "$SESSION")
    pair=$(fm_backend_herdr_create_task "$SESSION:$WS" "$label" "$FM_HOME" '') || fail 'display tab create unconfirmed'
    fm_backend_herdr_projection_focus_restore "$SESSION" "$focus" 'dot display create' || fail 'display focus changed'
    read -r tab pane <<< "$pair"
    RECORD=$(jq --arg c "$child" --arg t "$tab" --arg p "$pane" --arg l "$label" '.pending=false | .displays[$c]={tab:$t,pane:$p,label:$l}' <<< "$RECORD")
    save
    launch_reader "$pane" "$child"
  done < <({ printf 'console\n'; jq -r '.children[] | select(.display_required) | .id' "$SNAPSHOT"; })
  fm_lock_release "$LOCK"
  LOCK=''
  rm -f "$SNAPSHOT"
  SNAPSHOT=''
}
while :; do
  sync_view
  [ "$COMMAND" = watch ] || break
  sleep 5
done
