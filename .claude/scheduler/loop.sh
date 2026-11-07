#!/bin/bash
# v0 node scheduler. Every 10 minutes: find the first ready node (ready.py) and, if no session is
# running, start `claude -p "/node <ID>"` for it in its own worktree. One session at a time.
#   git worktree add --detach ~/gitrepos/themonolith-sched origin/main    (once; its own checkout, never the owner's)
#   cd ~/gitrepos/themonolith-sched && tmux new -d -s sched .claude/scheduler/loop.sh
#   touch ~/STOP                                         (exits at the next tick; a session keeps going)
# Node worktrees go in ../themonolith-wt/<ID>. SCHED_TICK overrides the 600 s tick (tests).
# Reads: ~/.config/noodlebot/token (GitHub App token for gh), ~/.config/claude-scheduler/oauth-token
# (CLAUDE_CODE_OAUTH_TOKEN, given to the session only). Writes: out/scheduler/status.log,
# out/node/<ID>/session.jsonl, out/node/<ID>/FAILED.
set -u -o pipefail
main=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
cd "$main" || exit 2
repo=tuckermclean/themonolith
here=.claude/scheduler
wtroot=$(dirname "$main")/themonolith-wt
oauth=$HOME/.config/claude-scheduler/oauth-token
log=out/scheduler/status.log
mkdir -p out/scheduler
declare -A starts
pid='' node=''

say() { echo "$(date -u +%FT%TZ) $*" >>"$log"; echo "$*"; }
ids() { sed -n 's#^node/\([A-Z][0-9][0-9]\)-.*#\1#p' | sort -u | tr '\n' ' '; }
[ -r "$oauth" ] || { echo "loop.sh: $oauth is missing (claude setup-token)" >&2; exit 2; }

tick() {
	git fetch -q origin || { say "git fetch failed; nothing started"; return; }
	local tok merged open
	tok=$(~/.config/noodlebot/token) || { say "no GitHub App token; nothing started"; return; }
	# pipefail: a failed gh must stop the tick, never read as "no PRs".
	if ! merged=$(GH_TOKEN=$tok gh pr list --repo $repo --state merged --limit 500 --json headRefName -q '.[].headRefName' | ids) ||
		! open=$(GH_TOKEN=$tok gh pr list --repo $repo --state open --limit 500 --json headRefName -q '.[].headRefName' | ids); then
		say "gh pr list failed; nothing started"; return
	fi
	local saw="open=[${open% }] merged-prs=[${merged% }]"

	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		say "$saw; session $node (pid $pid) running, log $(stat -c %s "out/node/$node/session.jsonl") bytes"
		return
	fi
	if [ -n "$pid" ]; then
		wait "$pid"; local rc=$?
		if [[ " $open $merged " == *" $node "* ]]; then say "$saw; session $node ended (rc $rc) with a PR"
		elif [ -e "out/node/$node/QUESTION.md" ]; then say "$saw; session $node ended (rc $rc) with QUESTION.md"
		elif [ "${starts[$node]}" -ge 2 ]; then
			echo "$(date -u +%FT%TZ) second exit (rc $rc) with no PR and no QUESTION.md" >"out/node/$node/FAILED"
			say "$saw; session $node ended (rc $rc), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
		else say "$saw; session $node ended (rc $rc), no PR, no QUESTION.md; may start again"
		fi
		pid='' node=''
	fi

	git show origin/main:docs/graph.yaml >out/scheduler/graph.yaml || { say "no graph on origin/main"; return; }
	git log --format=%s origin/main >out/scheduler/subjects.txt
	local args=() id next name wt
	for id in $merged; do args+=(--merged "$id"); done
	for id in $open; do args+=(--open "$id"); done
	next=$(python3 -I $here/ready.py --graph out/scheduler/graph.yaml --markers out/node \
		--subjects out/scheduler/subjects.txt "${args[@]}") || { say "$saw; ready.py failed; nothing started"; return; }
	[ -n "$next" ] || { say "$saw; nothing ready"; return; }
	id=${next%% *} name=${next#* }
	[ "${starts[$id]:-0}" -lt 2 ] || { say "$saw; $id ready but has used 2 starts; nothing started"; return; }

	wt=$wtroot/$id
	if [ ! -d "$wt" ]; then
		git worktree add -q -b "node/$id-$name" "$wt" origin/main 2>/dev/null ||
			git worktree add -q "$wt" "node/$id-$name" || { say "$saw; worktree for $id failed"; return; }
	fi
	mkdir -p "out/node/$id"
	sed -e "s|@ID@|$id|g" -e "s|@NAME@|$name|g" -e "s|@MAIN@|$main|g" -e "s|@WT@|$wt|g" \
		$here/unattended.md >"out/node/$id/unattended.md"
	(
		cd "$wt" || exit 2
		unset ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
		CLAUDE_CODE_OAUTH_TOKEN=$(cat "$oauth"); export CLAUDE_CODE_OAUTH_TOKEN
		exec claude -p "/node $id" --permission-mode auto --permission-prompts none \
			--output-format stream-json --verbose --append-system-prompt "$(cat "$main/out/node/$id/unattended.md")"
	) </dev/null >"out/node/$id/session.jsonl" 2>"out/node/$id/session.stderr" &
	pid=$! node=$id
	starts[$id]=$((${starts[$id]:-0} + 1))
	say "$saw; started $id ($name) in $wt, pid $pid, start ${starts[$id]} of 2"
}

while :; do
	[ -e ~/STOP ] && { say "found ~/STOP; loop exits (session ${node:-none} ${pid:+pid $pid }keeps running)"; exit 0; }
	tick
	sleep "${SCHED_TICK:-600}"
done
