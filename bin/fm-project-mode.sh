#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> +yolo +hardened] - <desc> ...     -> <mode> on, quality hardened
#
# Bracket grammar: the first token that does not begin with "+" is the mode, and
# every "+<flag>" token is position-independent. A "+<flag>" this version does not
# recognize is ignored rather than refused, so an older firstmate reading a newer
# registry keeps resolving the posture it does understand.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# +hardened = the registered quality posture. From the captain's side this is the
#   fourth option on the same list he picks from when he registers a project, after
#   no-mistakes, direct-PR and local-only; mechanically it is a separate token, so a
#   hardened project still carries one of those modes too. It is read with --quality
#   rather than through the two-word line, which is unchanged.
#   Absent means "standard": the ordinary path, with no extra quality loop.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# --quality prints ONE word instead, "standard" or "hardened". It is a separate
# output path precisely so the two-word stdout contract above stays untouched.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# The quality posture resolves independently of that fallback.
# A missing registry file, or a project absent from the registry, does yield "standard".
# An unrecognised mode token resets only the mode and the yolo flag and keeps a
# "+hardened" parsed beside it, because a typo in the mode must not silently drop the
# quality gate too; the unknown-mode warning still goes to stderr.
# "+hardened" beside "no-mistakes-prod-only" is the opposite case and drops to
# "standard" with its own stderr warning: a hardened project must pick a flat delivery
# mode, because a conditional policy decides per task and a quality standard covering
# only part of a project is not a statable posture
# (.agents/skills/project-management/SKILL.md "Delivery posture"). Unlike the typo,
# that combination parses cleanly and was ruled out on purpose. The mode still resolves
# to no-mistakes-prod-only, the two-word stdout is unchanged, and the exit stays 0.
# Usage: fm-project-mode.sh [--raw] [--quality] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
QUALITY_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift ;;
    --quality) QUALITY_ONLY=1; shift ;;
    *) break ;;
  esac
done
NAME=${1:?usage: fm-project-mode.sh [--raw] [--quality] <project-name>}

# One owner of the output shape, so the two-word default and the one-word
# --quality answer cannot drift apart across the fallback paths below.
emit() {  # <mode> <yolo> <quality>
  if [ "$QUALITY_ONLY" -eq 1 ]; then
    echo "$3"
  else
    echo "$1 $2"
  fi
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  emit no-mistakes off standard
  exit 0
fi

# awk emits "<mode> <yolo> <quality>" (one line) or nothing if the project is
# absent. A "+<flag>" token is never a mode, in any position, so the mode is the
# first bracket token that does not begin with "+".
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; quality="standard"; have_mode=0;
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j]=="+hardened") quality="hardened";
        else if (a[j] != "" && substr(a[j], 1, 1) != "+" && !have_mode) { mode=a[j]; have_mode=1 }
      }
    }
    print mode, yolo, quality; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  emit no-mistakes off standard
  exit 0
fi

read -r mode yolo quality <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$quality" in standard|hardened) ;; *) quality=standard ;; esac
if [ "$mode" = no-mistakes-prod-only ] && [ "$quality" = hardened ]; then
  echo "warn: +hardened is refused alongside the conditional policy no-mistakes-prod-only for $NAME; a hardened project must pick a flat delivery mode (no-mistakes, direct-PR or local-only), so defaulting quality to standard" >&2
  quality=standard
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
emit "$mode" "$yolo" "$quality"
