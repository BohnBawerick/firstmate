# Evidence: our fork becomes the default remote

## What a worker experiences

`careless-worker-transcript.txt` is a full CLI transcript of the same four
careless commands run twice against a fixture whose shape matches the real
repository (origin = third-party parent, fork = ours, local main authoritative
and published on ours, parent carrying an unreviewed commit).

Before the remap: the branch is cut from the parent, carries the parent's
unreviewed commit, misses our tree, and both `git push` and a flagless
`gh pr create` land on the parent.

After `bin/fm-landing-remote.sh apply`: the same commands cut from our main,
carry our tree, carry none of the parent's commit, and push and `gh pr create`
both land on ours. A worker running apply from a linked worktree is refused.

`gh` is stubbed (no network in this sandbox). The stub reproduces gh's own
default-repo rule: honor `remote.<name>.gh-resolved=base`, otherwise rank
upstream > github > origin > fork.

## Regression, sabotaged and restored

`sabotage-red.txt` - the two `git remote rename` calls in `cmd_apply` were
replaced with `true`, and `tests/fm-landing-remote.test.sh` goes red naming
the parent remote that would have received the work.

`restored-green.txt` - the file restored, all 14 cases pass.

`careless-worker-demo.sh` is the script that produced the transcript.
