#!/usr/bin/env bash
# End-to-end demonstration of the fork-default fix.
#
# Fixture mirrors the real shape: origin = third-party parent, fork = ours,
# local main authoritative and published on ours, parent carrying a commit
# that must never enter our tree.
#
# A worker then does the obvious thing with no special flags:
#   1. start from the spawn state (detached worktree on origin's tip)
#   2. git checkout -b fm/careless
#   3. git push          (no remote named)
#   4. gh pr create      (no --repo)
# Once before the remap, once after.
#
# gh is a stub: no network here. It reproduces gh's own default-repo rule -
# use the remote recorded in remote.<name>.gh-resolved=base, otherwise rank
# upstream > github > origin > fork - and prints the repository a flagless
# `gh pr create` would open the PR on.
set -eu

ROOT=$1
WORK=$2
rm -rf "$WORK"; mkdir -p "$WORK"

export GIT_AUTHOR_NAME=fm-test GIT_AUTHOR_EMAIL=fm-test@example.invalid
export GIT_COMMITTER_NAME=fm-test GIT_COMMITTER_EMAIL=fm-test@example.invalid

OURS="$WORK/ours.git"        # BohnBawerick/firstmate stand-in
PARENT="$WORK/parent.git"    # kunchenguid/firstmate stand-in
CLONE="$WORK/captain"        # firstmate's primary checkout

# --- fixture -----------------------------------------------------------------
mkdir -p "$WORK/seed"
git -C "$WORK/seed" init -q
git -C "$WORK/seed" checkout -q -b main
echo seed > "$WORK/seed/seed.txt"
git -C "$WORK/seed" add -A && git -C "$WORK/seed" commit -qm 'seed'
git clone -q --bare "$WORK/seed" "$PARENT"
git clone -q --bare "$WORK/seed" "$OURS"
git clone -q "file://$PARENT" "$CLONE"
git -C "$CLONE" remote add fork "file://$OURS"
git -C "$CLONE" fetch -q fork

echo 'our authoritative work' > "$CLONE/ours-only.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm 'ours: authoritative local main'
git -C "$CLONE" push -q fork main
git -C "$CLONE" fetch -q fork

git clone -q "$PARENT" "$WORK/parent-pub"
echo 'unreviewed third-party work' > "$WORK/parent-pub/third-party.txt"
git -C "$WORK/parent-pub" add -A
git -C "$WORK/parent-pub" commit -qm 'third party: unreviewed upstream commit'
git -C "$WORK/parent-pub" push -q origin main
git -C "$CLONE" fetch -q origin

# --- gh stub -----------------------------------------------------------------
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
resolve() {
  local n
  for n in origin upstream fork github; do
    if [ "$(git config --get "remote.$n.gh-resolved" || true)" = base ]; then
      printf '%s\n' "$n"; return 0
    fi
  done
  for n in upstream github origin fork; do
    if git config --get "remote.$n.url" >/dev/null 2>&1; then printf '%s\n' "$n"; return 0; fi
  done
  return 1
}
case "${1:-} ${2:-}" in
  "repo set-default")
    [ "${3:-}" = origin ] || exit 1
    git config remote.origin.gh-resolved base; exit 0 ;;
  "pr create")
    r=$(resolve)
    printf 'gh pr create -> remote %s -> %s\n' "$r" "$(git config --get "remote.$r.url")"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$WORK/fakebin/gh"
cat > "$WORK/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'no-mistakes %s\n' "$*"
SH
chmod +x "$WORK/fakebin/no-mistakes"
export PATH="$WORK/fakebin:$PATH"

# --- what a worker does, with no special flags -------------------------------
careless_worker() {  # <tag>
  local tag=$1
  local wt="$WORK/worker-$tag"
  local default
  git -C "$CLONE" fetch -q origin
  git -C "$CLONE" remote set-head origin --auto >/dev/null 2>&1 || true
  default=$(git -C "$CLONE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  git -C "$CLONE" worktree add -q --detach "$wt" "$default"   # the spawn state
  ( cd "$wt" && git checkout -q -b "fm/careless-$tag" )
  echo "  git checkout -b fm/careless-$tag  (from $default)"
  if [ -e "$wt/third-party.txt" ]; then
    echo "    tree: CARRIES the third party's unreviewed commit"
  else
    echo "    tree: clean of third-party commits"
  fi
  if [ -e "$wt/ours-only.txt" ]; then
    echo "    tree: contains our authoritative main"
  else
    echo "    tree: MISSING our authoritative main"
  fi
  echo "  git push (no remote named)"
  ( cd "$wt" && git push -q -u 2>/dev/null || git push -q -u origin HEAD 2>/dev/null || true )
  local pushed
  pushed=$(git -C "$wt" config --get "branch.fm/careless-$tag.remote" || echo '?')
  echo "    landed on remote '$pushed' -> $(git -C "$CLONE" config --get "remote.$pushed.url" || echo unknown)"
  echo "  $( cd "$wt" && gh pr create --title x --body y )"
  echo "  git pull on main would fetch from: $(git -C "$CLONE" config --get branch.main.remote || echo '(unset)')"
}

echo "=============================================================="
echo "remotes as the clone starts"
echo "=============================================================="
git -C "$CLONE" remote -v | sed 's/^/  /'
echo
echo "ours   (BohnBawerick stand-in) = file://$OURS"
echo "parent (kunchenguid stand-in)  = file://$PARENT"
echo
echo "=============================================================="
echo "BEFORE the fix: a worker doing the obvious thing"
echo "=============================================================="
careless_worker before
echo
echo "=============================================================="
echo "firstmate runs the remap on the primary checkout"
echo "  bin/fm-landing-remote.sh apply --ours <ours> --upstream <parent>"
echo "=============================================================="
"$ROOT/bin/fm-landing-remote.sh" apply --ours "file://$OURS" --upstream "file://$PARENT" --repo "$CLONE" 2>&1 | sed 's/^/  /'
echo
git -C "$CLONE" remote -v | sed 's/^/  /'
echo
echo "=============================================================="
echo "AFTER the fix: the same worker, the same commands, no flags"
echo "=============================================================="
careless_worker after
echo
echo "=============================================================="
echo "a worker in a linked worktree cannot retarget the fleet"
echo "=============================================================="
git -C "$CLONE" worktree add -q --detach "$WORK/worker-wt"
"$ROOT/bin/fm-landing-remote.sh" apply --ours "file://$OURS" --upstream "file://$PARENT" \
  --repo "$WORK/worker-wt" 2>&1 | sed 's/^/  /' || true
