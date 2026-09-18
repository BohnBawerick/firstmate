#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold those
# safeguards. PR runs supersede within one PR while main pushes are never
# cancelled. Every new PR head publishes the full result set without waiting
# for lint, and every CI job carries a finite hang tripwire.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>" from the workflow expression model.
# The parser supports context values, strings, equality, boolean operators,
# and parentheses. Unknown syntax fails instead of silently approximating it.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3 workflow=${4:-$CI_WORKFLOW} action=${5:-synchronize}
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
  "github.event.action" => ARGV[4],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

truthy = lambda { |v| v != false && v != nil && v != "" && v != 0 }
evaluate = lambda do |expression|
  tokens = expression.scan(/github\.[a-zA-Z0-9_.]+|\x27[^\x27]*\x27|==|\|\||&&|[()]/)
  raise "unsupported expression: #{expression}" unless tokens.join == expression.gsub(/\s+/, "")
  precedence = {"||" => 1, "&&" => 2, "==" => 3}
  parse = nil
  parse = lambda do |minimum|
    token = tokens.shift
    if token == "("
      left = parse.call(0)
      raise "missing closing parenthesis" unless tokens.shift == ")"
    else
      raise "missing operand" unless token
      left = value.call(token)
    end
    while precedence.fetch(tokens.first, -1) >= minimum
      operator = tokens.shift
      right = parse.call(precedence.fetch(operator) + 1)
      left = case operator
             when "==" then left == right
             when "&&" then truthy.call(left) ? right : left
             when "||" then truthy.call(left) ? left : right
             end
    end
    left
  end
  result = parse.call(0)
  raise "trailing expression tokens" unless tokens.empty?
  result.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$workflow" "$event" "$pr_number" "$run_id" "$action"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_non_pr_events_keep_independent_runs() {
  local event first second
  for event in push workflow_dispatch schedule release; do
    first=$(resolve_concurrency "$event" "" 910001) || fail "could not resolve $event"
    second=$(resolve_concurrency "$event" "" 910002) || fail "could not resolve $event"
    [ "$(group_of "$first")" != "$(group_of "$second")" ] || fail "$event runs share a group"
    [ "$(cancel_of "$first")" = false ] || fail "$event cancels work"
  done
  pass "non-PR events, including release work, keep independent non-cancelling runs"
}

test_compliance_body_events_keep_independent_groups() {
  local workflow action first second head other ordinary
  workflow="$ROOT/.github/workflows/no-mistakes-required.yml"
  ordinary=$(resolve_concurrency pull_request 108 920001) || fail "could not resolve ordinary CI"
  head=$(resolve_concurrency pull_request 108 920001 "$workflow" synchronize) || fail "could not resolve compliance"
  for action in opened edited; do
    first=$(resolve_concurrency pull_request 108 920001 "$workflow" "$action") || fail "could not resolve $action"
    second=$(resolve_concurrency pull_request 108 920002 "$workflow" "$action") || fail "could not resolve $action"
    other=$(resolve_concurrency pull_request 109 920001 "$workflow" "$action") || fail "could not resolve another PR"
    [ "$(group_of "$first")" != "$(group_of "$second")" ] || fail "$action body events can replace each other"
    [ "$(group_of "$first")" != "$(group_of "$head")" ] || fail "$action body events share a head-change group"
    [ "$(group_of "$first")" != "$(group_of "$other")" ] || fail "distinct compliance PRs share a group"
    [ "$(group_of "$first")" != "$(group_of "$ordinary")" ] || fail "ordinary CI can replace compliance work"
  done
  pass "compliance body events retain independent per-event groups"
}

test_each_pr_head_reports_the_complete_ci_result_set() {
  local actual expected
  # shellcheck disable=SC2016 # The GitHub matrix expression is literal Ruby input.
  actual=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
pull_request = doc.fetch(true).fetch("pull_request")
raise "CI no longer runs for pull requests to main" unless pull_request.fetch("branches").include?("main")

doc.fetch("jobs").each do |id, job|
  condition = job["if"]
  unless condition.nil? || condition == "always()"
    raise "#{id} can omit its result from a PR head through job-level condition #{condition.inspect}"
  end

  name = job.fetch("name")
  matrix = job.dig("strategy", "matrix")
  if matrix
    raise "#{id} has an unmodelled result matrix" unless matrix.keys == ["shard"]
    matrix.fetch("shard").each { |shard| puts name.gsub("${{ matrix.shard }}", shard.to_s) }
  else
    puts name
  end
end
' "$CI_WORKFLOW") || fail "could not resolve the PR result set"
  expected=$(cat <<'RESULTS'
Lint
Test coverage guard
Behavior portable parallel 1
Behavior portable parallel 2
Behavior portable serial 1
Behavior portable serial 2
Behavior portable serial 3
Behavior portable serial 4
Behavior portable serial 5
Behavior tests (Herdr)
Behavior timing aggregate
Stock macOS Bash snapshot compatibility
Repo invariants
RESULTS
)
  [ "$actual" = "$expected" ] \
    || fail "a PR head no longer publishes the complete CI result set:"$'\n'"$actual"
  pass "every PR head publishes the complete CI result set"
}

test_ci_suite_does_not_wait_for_lint() {
  local blocked
  blocked=$(ruby -ryaml -e '
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
depends_on_lint = lambda do |id, seen|
  raise "dependency cycle at #{id}" if seen.include?(id)
  needs = Array(jobs.fetch(id)["needs"])
  needs.include?("lint") || needs.any? { |need| depends_on_lint.call(need, seen + [id]) }
end
jobs.each_key { |id| puts id if id != "lint" && depends_on_lint.call(id, []) }
' "$CI_WORKFLOW") || fail "could not resolve CI job dependencies"
  [ -z "$blocked" ] \
    || fail "these CI jobs wait for lint instead of starting independently:"$'\n'"$blocked"
  pass "the CI suite starts independently of lint"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# The four jobs the incident found unbounded, at the report's recommended caps.
test_previously_unbounded_jobs_keep_their_caps() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
lint 25
test-coverage 5
tests-timing-aggregate 5
invariants 5
CAPS
  pass "the incident's unbounded jobs keep their recommended caps"
}

# Cancellation makes an undersized cap costlier: a falsely tripped job now also
# discards a run nobody replaced. These bounds were measured, not guessed.
test_measured_lanes_keep_their_existing_bounds() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
tests-portable-parallel-1 15
tests-portable-parallel-2 15
tests-portable-serial 30
tests-herdr 75
macos-stock-bash 10
CAPS
  pass "the already-measured lane bounds are unchanged"
}

test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_non_pr_events_keep_independent_runs
test_compliance_body_events_keep_independent_groups
test_each_pr_head_reports_the_complete_ci_result_set
test_ci_suite_does_not_wait_for_lint
test_every_job_has_a_finite_timeout
test_previously_unbounded_jobs_keep_their_caps
test_measured_lanes_keep_their_existing_bounds
