set -u
G=.claude/hooks/guard.py; ok=0; bad=0
t() { want=$1; role=$2; json=$3; printf '%s' "$json" | CLAUDE_PROJECT_DIR=$PWD python3 -I $G $role 2>/dev/null; got=$?; if [ "$got" = "$want" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "MISMATCH want=$want got=$got $role $json"; fi; }
t 2 session '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 3"}}'
t 0 session '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x"}}'
t 2 tester '{"tool_name":"Write","tool_input":{"file_path":"scripts/build-packages.sh","content":"x"}}'
t 0 tester '{"tool_name":"Write","tool_input":{"file_path":"scripts/tests/new.test.sh","content":"x"}}'
t 2 implementer '{"tool_name":"Edit","tool_input":{"file_path":"nodes/B01-package-build.md"}}'
t 2 implementer '{"tool_name":"Bash","tool_input":{"command":"echo x > SPEC.md"}}'
t 2 implementer '{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD"}}'
t 0 implementer '{"tool_name":"Write","tool_input":{"file_path":".github/workflows/build.yml","content":"x"}}'
t 2 reviewer '{"tool_name":"Write","tool_input":{"file_path":"scripts/x.sh","content":"x"}}'
t 2 reviewer '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
echo "guard cases ok=$ok bad=$bad"
