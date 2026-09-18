#!/usr/bin/env bash
# Live drive: real fm-contributions.sh poll against real GitHub PRs (read-only), gh calls logged by a pass-through spy.
set -u
ROOT=$1; H=/tmp/nmtest-contrib
rm -rf "$H"; mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$H/fakebin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/no-mistakes"
REAL=$(command -v gh)
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh-calls.log"\nexec %s "$@"\n' "$H" "$REAL" > "$H/fakebin/gh"; chmod +x "$H/fakebin/"*
printf '# Backlog\n\n## Queued\n' > "$H/data/backlog.md"
for n in 4800 4799 4788 4783 4779 4778 4777 4775 4738 4710 4692 4689; do
  printf -- '- [ ] merged-%s - Upstream contribution https://github.com/kunchenguid/firstmate/pull/%s (repo: firstmate) (kind: ship)\n' "$n" "$n" >> "$H/data/backlog.md"
done
printf -- '- [ ] open-4804 - Upstream contribution https://github.com/kunchenguid/firstmate/pull/4804 (repo: firstmate) (kind: ship)\n' >> "$H/data/backlog.md"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml" 2>/dev/null || true
poll() { PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_CONTRIBUTIONS_BUDGET=25 "$ROOT/bin/fm-contributions.sh" poll; }
summ() { for f in "$H"/data/*/contributions.json; do jq -r '.task as $t | .records[] | [$t, (.observation.state // "none"), .checked_at, (.error // "-"), ((.pending|length)|tostring)+" pending"] | @tsv' "$f"; done; }
for round in 1 2 3; do
  : > "$H/gh-calls.log"
  echo "=== poll $round"; poll 2>&1 | cut -c1-200 | sed 's/^/  out: /'; echo "  exit=${PIPESTATUS[0]}"
  echo "  records:"; summ | sed 's/^/    /'
  echo "  forge reads this poll per PR:"; grep -oE 'pulls/[0-9]+' "$H/gh-calls.log" | sort | uniq -c | sed 's/^/    /'
  echo "  total gh calls: $(wc -l < "$H/gh-calls.log")"
done
