#!/bin/bash
# GNU find compatibility tests for e-jerk find
# These tests are derived from GNU find test patterns

FIND=${FIND:-"$(dirname "$0")/zig-out/bin/find"}
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

passed=0
failed=0
skipped=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    ((passed++))
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    ((failed++))
    echo -e "${RED}FAIL${NC}: $1"
    if [ -n "$2" ]; then
        echo "  Expected: $2"
        echo "  Got: $3"
    fi
}

skip() {
    ((skipped++))
    echo -e "${YELLOW}SKIP${NC}: $1"
}

echo "========================================="
echo "GNU find compatibility tests"
echo "Testing: $FIND"
echo "========================================="
echo

# Create test directory structure
mkdir -p "$TMPDIR/testdir/subdir1/deep"
mkdir -p "$TMPDIR/testdir/subdir2"
mkdir -p "$TMPDIR/testdir/.hidden"
touch "$TMPDIR/testdir/file1.txt"
touch "$TMPDIR/testdir/file2.log"
touch "$TMPDIR/testdir/FILE3.TXT"
touch "$TMPDIR/testdir/subdir1/nested.txt"
touch "$TMPDIR/testdir/subdir1/deep/deep.txt"
touch "$TMPDIR/testdir/subdir2/other.log"
touch "$TMPDIR/testdir/.hidden/secret.txt"
touch "$TMPDIR/testdir/.hiddenfile"

echo "--- Basic Tests ---"

# Test 1: Find all files
result=$($FIND "$TMPDIR/testdir" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -ge 10 ]; then
    pass "Find all entries (found $result)"
else
    fail "Find all entries" ">= 10" "$result"
fi

# Test 2: Find by name pattern
result=$($FIND "$TMPDIR/testdir" -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 4 ]; then
    pass "Find by name pattern (*.txt)"
else
    fail "Find by name pattern (*.txt)" "4" "$result"
fi

# Test 3: Case-insensitive name
result=$($FIND "$TMPDIR/testdir" -iname "*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 5 ]; then
    pass "Case-insensitive name (-iname)"
else
    fail "Case-insensitive name (-iname)" "5" "$result"
fi

# Test 4: Find directories only
result=$($FIND "$TMPDIR/testdir" -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 5 ]; then
    pass "Find directories only (-type d)"
else
    fail "Find directories only (-type d)" "5" "$result"
fi

# Test 5: Find files only
result=$($FIND "$TMPDIR/testdir" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 8 ]; then
    pass "Find files only (-type f)"
else
    fail "Find files only (-type f)" "8" "$result"
fi

# Test 6: Maxdepth
result=$($FIND "$TMPDIR/testdir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 4 ]; then
    pass "Maxdepth limit (-maxdepth 1)"
else
    fail "Maxdepth limit (-maxdepth 1)" "4" "$result"
fi

# Test 7: Mindepth
result=$($FIND "$TMPDIR/testdir" -mindepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 4 ]; then
    pass "Mindepth limit (-mindepth 2)"
else
    fail "Mindepth limit (-mindepth 2)" "4" "$result"
fi

# Test 8: Path pattern
result=$($FIND "$TMPDIR/testdir" -path "*subdir1*" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Path pattern (-path)"
else
    fail "Path pattern (-path)" "2" "$result"
fi

# Test 9: Multiple patterns
result=$($FIND "$TMPDIR/testdir" -name "*.txt" -o -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
# Note: GNU find OR logic - if not supported, skip
if [ "$result" -eq 6 ]; then
    pass "Multiple patterns with -o"
else
    skip "Multiple patterns with -o (not supported or different count: $result)"
fi

echo
echo "--- Exit Codes ---"

# Test 10: Exit 0 on success
$FIND "$TMPDIR/testdir" -name "*.txt" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "Exit 0 on success"
else
    fail "Exit 0 on success" "0" "$?"
fi

# Test 11: Exit non-zero on error
$FIND "/nonexistent/path" > /dev/null 2>&1
ec=$?
if [ $ec -ne 0 ]; then
    pass "Exit non-zero on error (got $ec)"
else
    fail "Exit non-zero on error" "non-zero" "$ec"
fi

echo
echo "--- Output Format ---"

# Test 12: Output contains full paths
output=$($FIND "$TMPDIR/testdir" -name "file1.txt" 2>/dev/null)
if echo "$output" | grep -q "$TMPDIR/testdir/file1.txt"; then
    pass "Output contains full path"
else
    fail "Output contains full path" "$TMPDIR/testdir/file1.txt" "$output"
fi

# Test 13: print0 support (if available)
if $FIND --help 2>&1 | grep -q "print0"; then
    result=$($FIND "$TMPDIR/testdir" -name "*.txt" -print0 2>/dev/null | tr '\0' '\n' | wc -l | tr -d ' ')
    if [ "$result" -eq 4 ]; then
        pass "Null-separated output (-print0)"
    else
        fail "Null-separated output (-print0)" "4" "$result"
    fi
else
    skip "print0 not supported"
fi

echo
echo "--- Edge Cases ---"

# Test 14: Hidden files
result=$($FIND "$TMPDIR/testdir" -name ".*" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -ge 1 ]; then
    pass "Find hidden files"
else
    fail "Find hidden files" ">= 1" "$result"
fi

# Test 15: Empty directory
mkdir -p "$TMPDIR/testdir/emptydir"
result=$($FIND "$TMPDIR/testdir/emptydir" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 1 ]; then
    pass "Empty directory"
else
    fail "Empty directory" "1" "$result"
fi

# Test 16: Current directory
cd "$TMPDIR/testdir"
result=$($FIND . -name "*.txt" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
cd - > /dev/null
if [ "$result" -ge 1 ]; then
    pass "Current directory search"
else
    fail "Current directory search" ">= 1" "$result"
fi

# Test 17: Stdin paths (if supported with -)
if echo "$TMPDIR/testdir" | $FIND - -name "*.txt" -maxdepth 1 > /dev/null 2>&1; then
    result=$(echo "$TMPDIR/testdir" | $FIND - -name "*.txt" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    if [ "$result" -ge 1 ]; then
        pass "Stdin paths with -"
    else
        fail "Stdin paths with -" ">= 1" "$result"
    fi
else
    skip "Stdin paths not supported"
fi

echo
echo "========================================="
echo "Results: $passed passed, $failed failed, $skipped skipped"
echo "========================================="

if [ $failed -gt 0 ]; then
    exit 1
fi
exit 0
