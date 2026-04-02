#!/bin/bash
# Tests for session-log.sh PostToolUse hook
# Run: bash tests/test-session-log.sh

set -euo pipefail

HOOK="$HOME/.claude/hooks/session-log.sh"
PASS=0
FAIL=0
TEST_SESSION="test-$$"

cleanup() {
  rm -f "/tmp/session-log-${TEST_SESSION}.jsonl"
  rm -f "/tmp/session-log-$(date +%s)-$$.jsonl" 2>/dev/null
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if echo "$text" | grep -q "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern='$pattern' not found)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" pattern="$2" text="$3"
  if echo "$text" | grep -q "$pattern"; then
    echo "  FAIL: $desc (pattern='$pattern' found but shouldn't be)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

# --- Test 1: Basic Bash tool logging ---
echo "Test 1: Basic Bash tool logging"
echo '{"tool_name":"Bash","session_id":"'"$TEST_SESSION"'","tool_input":{"command":"ls -la"},"tool_result":{"stdout":"file1.txt\nfile2.txt","exit_code":0}}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl" 2>/dev/null)
assert_contains "JSONL line created" '"tool":"Bash"' "$LINE"
assert_contains "input captured" '"input":"ls -la"' "$LINE"
assert_contains "exit_code captured" '"exit_code":0' "$LINE"
# Validate JSON
echo "$LINE" | jq . >/dev/null 2>&1
assert_eq "Valid JSON" "0" "$?"

# --- Test 2: Edit tool logging ---
echo "Test 2: Edit tool logging"
echo '{"tool_name":"Edit","session_id":"'"$TEST_SESSION"'","tool_input":{"file_path":"/tmp/foo.txt"},"tool_result":"ok"}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_contains "Edit tool captured" '"tool":"Edit"' "$LINE"
assert_contains "file_path as input" '"/tmp/foo.txt"' "$LINE"

# --- Test 3: Write tool logging ---
echo "Test 3: Write tool logging"
echo '{"tool_name":"Write","session_id":"'"$TEST_SESSION"'","tool_input":{"file_path":"/tmp/bar.txt"},"tool_result":"ok"}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_contains "Write tool captured" '"tool":"Write"' "$LINE"

# --- Test 4: Non-matching tool ignored ---
echo "Test 4: Non-matching tool (Read) ignored"
LINES_BEFORE=$(wc -l < "/tmp/session-log-${TEST_SESSION}.jsonl")
echo '{"tool_name":"Read","session_id":"'"$TEST_SESSION"'","tool_input":{"file_path":"/tmp/x"},"tool_result":"data"}' | bash "$HOOK"
LINES_AFTER=$(wc -l < "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_eq "Read tool not logged" "$LINES_BEFORE" "$LINES_AFTER"

# --- Test 5: Missing session_id uses fallback ---
echo "Test 5: Missing session_id uses fallback (not empty)"
echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_result":{"stdout":"hi","exit_code":0}}' | bash "$HOOK"
# Should create a file with fallback session id — find it
FALLBACK_FILE=$(ls -t /tmp/session-log-*.jsonl 2>/dev/null | grep -v "$TEST_SESSION" | head -1)
if [ -n "$FALLBACK_FILE" ]; then
  echo "  PASS: Fallback file created: $(basename $FALLBACK_FILE)"
  PASS=$((PASS + 1))
  rm -f "$FALLBACK_FILE"
else
  echo "  FAIL: No fallback file created"
  FAIL=$((FAIL + 1))
fi

# --- Test 6: Secret redaction ---
echo "Test 6: Secret redaction"
echo '{"tool_name":"Bash","session_id":"'"$TEST_SESSION"'","tool_input":{"command":"curl -H sk-1234567890abcdefghijklmnop"},"tool_result":{"stdout":"ok","exit_code":0}}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_not_contains "sk- key redacted" "sk-1234567890" "$LINE"
assert_contains "redaction marker present" "REDACTED" "$LINE"

# --- Test 7: AWS key redaction ---
echo "Test 7: AWS key redaction"
echo '{"tool_name":"Bash","session_id":"'"$TEST_SESSION"'","tool_input":{"command":"export AWS_KEY=AKIAIOSFODNN7EXAMPLE"},"tool_result":{"stdout":"","exit_code":0}}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_not_contains "AWS key redacted" "AKIAIOSFODNN7EXAMPLE" "$LINE"
assert_contains "AWS redaction marker" "REDACTED_AWS" "$LINE"

# --- Test 8: JWT redaction ---
echo "Test 8: JWT redaction"
echo '{"tool_name":"Bash","session_id":"'"$TEST_SESSION"'","tool_input":{"command":"curl -H Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"},"tool_result":{"stdout":"","exit_code":0}}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_not_contains "JWT redacted" "eyJhbGciOiJ" "$LINE"
assert_contains "JWT redaction marker" "REDACTED_JWT" "$LINE"

# --- Test 9: Path traversal blocked ---
echo "Test 9: Path traversal in session_id blocked"
echo '{"tool_name":"Bash","session_id":"../../etc/passwd","tool_input":{"command":"echo x"},"tool_result":{"stdout":"x","exit_code":0}}' | bash "$HOOK"
# basename strips traversal → "passwd" which is safe (stays in /tmp)
assert_eq "File stays in /tmp (safe)" "0" "$(test -f /tmp/session-log-passwd.jsonl 2>/dev/null; echo $?)"
rm -f /tmp/session-log-passwd.jsonl
# Verify no file written outside /tmp
assert_eq "No file at traversal target" "1" "$(test -f /etc/session-log-passwd.jsonl 2>/dev/null; echo $?)"

# --- Test 10: Secret redaction in OUTPUT ---
echo "Test 10: Secret redaction in output field"
echo '{"tool_name":"Bash","session_id":"'"$TEST_SESSION"'","tool_input":{"command":"cat creds"},"tool_result":{"stdout":"token=sk-abcdefghijklmnopqrstuvwxyz123","exit_code":0}}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_not_contains "sk- redacted in output" "sk-abcdefghij" "$LINE"
assert_contains "output redaction marker" "REDACTED" "$LINE"

# --- Test 11: Non-numeric exit_code handled ---
echo "Test 11: Non-numeric exit_code (e.g. 'timeout') handled"
echo '{"tool_name":"Bash","session_id":"'"$TEST_SESSION"'","tool_input":{"command":"slow-cmd"},"tool_result":{"stdout":"","exit_code":"timeout"}}' | bash "$HOOK"
LINE=$(tail -1 "/tmp/session-log-${TEST_SESSION}.jsonl")
assert_contains "exit_code normalized to null" '"exit_code":null' "$LINE"
echo "$LINE" | jq . >/dev/null 2>&1
assert_eq "Valid JSON with non-numeric exit_code" "0" "$?"

# --- Test 12: Hook always exits 0 ---
echo "Test 12: Hook always exits 0"
echo '{}' | bash "$HOOK"
assert_eq "Exit code is 0" "0" "$?"

# --- Summary ---
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
