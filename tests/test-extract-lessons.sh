#!/bin/bash
# Tests for extract-lessons.sh
# Run: bash tests/test-extract-lessons.sh

set -euo pipefail

SCRIPT="$HOME/.claude/hooks/extract-lessons.sh"
PASS=0
FAIL=0
TESTDIR=$(mktemp -d)

cleanup() {
  rm -rf "$TESTDIR"
}
trap cleanup EXIT

assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if echo "$text" | grep -qi "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern='$pattern' not found)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" pattern="$2" text="$3"
  if echo "$text" | grep -qi "$pattern"; then
    echo "  FAIL: $desc (pattern='$pattern' found but shouldn't be)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

assert_empty() {
  local desc="$1" text="$2"
  if [ -z "$text" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected empty, got '${text:0:50}...')"
    FAIL=$((FAIL + 1))
  fi
}

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

# --- Test 1: Error with exit_code != 0 detected ---
echo "Test 1: Error with exit_code != 0 detected"
cat > "$TESTDIR/test1.jsonl" << 'EOF'
{"ts":1000,"tool":"Bash","input":"npm test","output":"FAIL: 3 tests failed","exit_code":1}
{"ts":1001,"tool":"Bash","input":"echo ok","output":"ok","exit_code":0}
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test1.jsonl")
assert_contains "Error found" "npm test" "$RESULT"
assert_contains "Error output shown" "3 tests failed" "$RESULT"
assert_contains "Header present" "Lezioni dalla sessione" "$RESULT"

# --- Test 2: Error pattern in output (exit_code 0) ---
echo "Test 2: Error pattern in output detected"
cat > "$TESTDIR/test2.jsonl" << 'EOF'
{"ts":1000,"tool":"Bash","input":"make build","output":"fatal error: file not found","exit_code":0}
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test2.jsonl")
assert_contains "Pattern-based error found" "make build" "$RESULT"
assert_contains "Error output" "not found" "$RESULT"

# --- Test 3: Fix detection (retry after error) ---
echo "Test 3: Fix detection within window"
cat > "$TESTDIR/test3.jsonl" << 'EOF'
{"ts":1000,"tool":"Bash","input":"pip install foo","output":"ERROR: No matching distribution","exit_code":1}
{"ts":1001,"tool":"Bash","input":"pip install foo==1.2","output":"Successfully installed foo-1.2","exit_code":0}
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test3.jsonl")
assert_contains "Error found" "pip install foo" "$RESULT"
assert_contains "Fix section present" "Fix" "$RESULT"
assert_contains "Fix output" "Successfully installed" "$RESULT"

# --- Test 4: Normal entries filtered out ---
echo "Test 4: Normal entries (no error) filtered out"
cat > "$TESTDIR/test4.jsonl" << 'EOF'
{"ts":1000,"tool":"Bash","input":"ls -la","output":"file1.txt\nfile2.txt","exit_code":0}
{"ts":1001,"tool":"Edit","input":"/tmp/foo.txt","output":"ok","exit_code":null}
{"ts":1002,"tool":"Bash","input":"git status","output":"On branch main","exit_code":0}
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test4.jsonl")
assert_empty "No errors → empty output" "$RESULT"

# --- Test 5: Empty file → empty output ---
echo "Test 5: Empty file → empty output"
touch "$TESTDIR/test5.jsonl"
RESULT=$(bash "$SCRIPT" "$TESTDIR/test5.jsonl")
assert_empty "Empty file → empty" "$RESULT"
assert_eq "Exit code 0" "0" "$?"

# --- Test 6: Missing file → exit 0 ---
echo "Test 6: Missing file → exit 0"
RESULT=$(bash "$SCRIPT" "$TESTDIR/nonexistent.jsonl")
assert_empty "Missing file → empty" "$RESULT"
assert_eq "Exit code 0" "0" "$?"

# --- Test 7: No argument → exit 0 ---
echo "Test 7: No argument → exit 0"
RESULT=$(bash "$SCRIPT")
assert_empty "No arg → empty" "$RESULT"
assert_eq "Exit code 0" "0" "$?"

# --- Test 8: Case-insensitive pattern matching ---
echo "Test 8: Case-insensitive error detection"
cat > "$TESTDIR/test8.jsonl" << 'EOF'
{"ts":1000,"tool":"Bash","input":"cargo build","output":"PERMISSION DENIED on /usr/lib","exit_code":0}
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test8.jsonl")
assert_contains "Case-insensitive match" "cargo build" "$RESULT"

# --- Test 9: Output in code blocks ---
echo "Test 9: Output wrapped in code blocks"
cat > "$TESTDIR/test9.jsonl" << 'EOF'
{"ts":1000,"tool":"Bash","input":"npm run build","output":"Error: module not found","exit_code":1}
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test9.jsonl")
assert_contains "Code block present" '```' "$RESULT"

# --- Test 10: Invalid JSON lines skipped ---
echo "Test 10: Invalid JSON lines skipped gracefully"
cat > "$TESTDIR/test10.jsonl" << 'EOF'
not valid json
{"ts":1000,"tool":"Bash","input":"failing cmd","output":"Error occurred","exit_code":1}
also not json {{{
EOF
RESULT=$(bash "$SCRIPT" "$TESTDIR/test10.jsonl")
assert_contains "Valid error still found" "failing cmd" "$RESULT"

# --- Summary ---
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
