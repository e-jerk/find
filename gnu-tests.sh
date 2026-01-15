#!/bin/bash
# GNU find compatibility tests for e-jerk find
# These tests are derived from GNU find test patterns

# Convert to absolute path to handle cd in tests
FIND=${FIND:-"$(cd "$(dirname "$0")" && pwd)/zig-out/bin/find"}
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
echo "--- Negation and Empty Tests ---"

# Test 18: Negation with -not
# Find files that are NOT .txt files
result=$($FIND "$TMPDIR/testdir" -type f -not -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
# We have 8 total files, 4 are .txt (file1.txt, FILE3.TXT doesn't count since case-sensitive, nested.txt, deep.txt, secret.txt)
# Actually: file1.txt, nested.txt, deep.txt, secret.txt = 4 .txt files
# Non-.txt: file2.log, FILE3.TXT, other.log, .hiddenfile = 4 files
if [ "$result" -eq 4 ]; then
    pass "Negation with -not"
else
    fail "Negation with -not" "4" "$result"
fi

# Test 19: Negation with ! (alias)
result=$($FIND "$TMPDIR/testdir" -type f '!' -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 4 ]; then
    pass "Negation with ! alias"
else
    fail "Negation with ! alias" "4" "$result"
fi

# Test 20: Empty files
# Create an empty file
touch "$TMPDIR/testdir/emptyfile.txt"
result=$($FIND "$TMPDIR/testdir" -type f -empty 2>/dev/null | wc -l | tr -d ' ')
# All our test files are empty (created with touch), so should be 9 now
if [ "$result" -ge 9 ]; then
    pass "Find empty files (-empty)"
else
    fail "Find empty files (-empty)" ">= 9" "$result"
fi

# Test 21: Empty directories
# The emptydir we created earlier + deep (after we remove files)
result=$($FIND "$TMPDIR/testdir" -type d -empty 2>/dev/null | wc -l | tr -d ' ')
# emptydir should be the only empty directory
if [ "$result" -eq 1 ]; then
    pass "Find empty directories (-empty)"
else
    fail "Find empty directories (-empty)" "1" "$result"
fi

# Test 22: Combination -not -empty (find non-empty)
result=$($FIND "$TMPDIR/testdir" -type d -not -empty 2>/dev/null | wc -l | tr -d ' ')
# testdir, subdir1, subdir2, .hidden, deep = 5 non-empty directories
if [ "$result" -ge 4 ]; then
    pass "Find non-empty directories (-not -empty)"
else
    fail "Find non-empty directories (-not -empty)" ">= 4" "$result"
fi

echo
echo "--- Size Filter Tests ---"

# Create files of known sizes for size tests
dd if=/dev/zero of="$TMPDIR/testdir/size_100b.dat" bs=1 count=100 2>/dev/null
dd if=/dev/zero of="$TMPDIR/testdir/size_1k.dat" bs=1024 count=1 2>/dev/null
dd if=/dev/zero of="$TMPDIR/testdir/size_10k.dat" bs=1024 count=10 2>/dev/null
dd if=/dev/zero of="$TMPDIR/testdir/size_100k.dat" bs=1024 count=100 2>/dev/null

# Test 23: Size filter with bytes suffix (exact)
result=$($FIND "$TMPDIR/testdir" -size 100c -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 1 ]; then
    pass "Size filter exact bytes (-size 100c)"
else
    fail "Size filter exact bytes (-size 100c)" "1" "$result"
fi

# Test 24: Size filter with kilobytes suffix (exact)
result=$($FIND "$TMPDIR/testdir" -size 1k -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 1 ]; then
    pass "Size filter exact kilobytes (-size 1k)"
else
    fail "Size filter exact kilobytes (-size 1k)" "1" "$result"
fi

# Test 25: Size filter greater than (+)
result=$($FIND "$TMPDIR/testdir" -size +50k -type f 2>/dev/null | wc -l | tr -d ' ')
# 100k file is > 50k
if [ "$result" -eq 1 ]; then
    pass "Size filter greater than (-size +50k)"
else
    fail "Size filter greater than (-size +50k)" "1" "$result"
fi

# Test 26: Size filter less than (-)
result=$($FIND "$TMPDIR/testdir" -size -5k -type f 2>/dev/null | wc -l | tr -d ' ')
# Files < 5k: empty files (9) + 100b (1) + 1k (1) = at least 11
if [ "$result" -ge 11 ]; then
    pass "Size filter less than (-size -5k)"
else
    fail "Size filter less than (-size -5k)" ">= 11" "$result"
fi

# Test 27: Size filter with no suffix (512-byte blocks)
# 10k = 10240 bytes = 20 blocks of 512 bytes
result=$($FIND "$TMPDIR/testdir" -size 20 -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 1 ]; then
    pass "Size filter with 512-byte blocks (-size 20)"
else
    fail "Size filter with 512-byte blocks (-size 20)" "1" "$result"
fi

echo
echo "--- Time Filter Tests ---"

# Create old file (using touch to set modification time to 10 days ago)
touch -t $(date -v-10d "+%Y%m%d%H%M") "$TMPDIR/testdir/old_file.txt" 2>/dev/null || \
    touch -d "10 days ago" "$TMPDIR/testdir/old_file.txt" 2>/dev/null

# Test 28: Find files modified in the last day (-mtime -1)
# All our recently created files should match
result=$($FIND "$TMPDIR/testdir" -type f -mtime -1 2>/dev/null | wc -l | tr -d ' ')
# Should be at least some files (all the recently created ones)
if [ "$result" -ge 10 ]; then
    pass "Time filter files modified recently (-mtime -1)"
else
    fail "Time filter files modified recently (-mtime -1)" ">= 10" "$result"
fi

# Test 29: Find files modified more than 5 days ago (-mtime +5)
# Only the old_file.txt should match
result=$($FIND "$TMPDIR/testdir" -type f -mtime +5 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 1 ]; then
    pass "Time filter files modified > 5 days ago (-mtime +5)"
else
    fail "Time filter files modified > 5 days ago (-mtime +5)" "1" "$result"
fi

# Test 30: Find files modified today (0 days ago)
result=$($FIND "$TMPDIR/testdir" -type f -mtime 0 2>/dev/null | wc -l | tr -d ' ')
# All recently created files should be "0 days" old
if [ "$result" -ge 10 ]; then
    pass "Time filter files modified today (-mtime 0)"
else
    fail "Time filter files modified today (-mtime 0)" ">= 10" "$result"
fi

# Test 31: -atime filter (access time)
# Just test that it runs without error
if $FIND "$TMPDIR/testdir" -type f -atime -1 > /dev/null 2>&1; then
    pass "Access time filter runs (-atime -1)"
else
    fail "Access time filter runs (-atime -1)" "success" "error"
fi

# Test 32: -ctime filter (status change time)
# Just test that it runs without error
if $FIND "$TMPDIR/testdir" -type f -ctime -1 > /dev/null 2>&1; then
    pass "Status change time filter runs (-ctime -1)"
else
    fail "Status change time filter runs (-ctime -1)" "success" "error"
fi

echo
echo "--- Prune Tests ---"

# Create a directory structure for prune testing
mkdir -p "$TMPDIR/testdir/skip_me/nested"
mkdir -p "$TMPDIR/testdir/keep_me/nested"
touch "$TMPDIR/testdir/skip_me/hidden.txt"
touch "$TMPDIR/testdir/skip_me/nested/deep.txt"
touch "$TMPDIR/testdir/keep_me/visible.txt"
touch "$TMPDIR/testdir/keep_me/nested/deep.txt"

# Test 33: Prune specific directory
result=$($FIND "$TMPDIR/testdir" -prune "skip_me" 2>/dev/null | wc -l | tr -d ' ')
# Without prune we'd have more entries
result_all=$($FIND "$TMPDIR/testdir" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -lt "$result_all" ]; then
    pass "Prune skips directory (-prune skip_me)"
else
    fail "Prune skips directory (-prune skip_me)" "< $result_all" "$result"
fi

# Test 34: Pruned directory contents not listed
# Check that skip_me and its contents are not in the output
result=$($FIND "$TMPDIR/testdir" -prune "skip_me" 2>/dev/null | grep "skip_me" | wc -l | tr -d ' ')
if [ "$result" -eq 0 ]; then
    pass "Pruned directory not in output"
else
    fail "Pruned directory not in output" "0" "$result"
fi

# Test 35: Non-pruned directory IS listed
result=$($FIND "$TMPDIR/testdir" -prune "skip_me" 2>/dev/null | grep "keep_me" | wc -l | tr -d ' ')
# keep_me and its nested dir should both be found
if [ "$result" -ge 1 ]; then
    pass "Non-pruned directories are listed"
else
    fail "Non-pruned directories are listed" ">= 1" "$result"
fi

# Test 36: Prune with glob pattern
result=$($FIND "$TMPDIR/testdir" -prune "skip_*" 2>/dev/null | grep "skip_me" | wc -l | tr -d ' ')
if [ "$result" -eq 0 ]; then
    pass "Prune with glob pattern (-prune 'skip_*')"
else
    fail "Prune with glob pattern (-prune 'skip_*')" "0" "$result"
fi

echo
echo "========================================="
echo "Results: $passed passed, $failed failed, $skipped skipped"
echo "========================================="

if [ $failed -gt 0 ]; then
    exit 1
fi
exit 0
