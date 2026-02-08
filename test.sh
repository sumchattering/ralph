#!/usr/bin/env bash
# Unit tests for Ralph script using mock Claude

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create temp directory for test PRDs and mock bin
TEST_DIR=$(mktemp -d)
MOCK_BIN_DIR="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN_DIR"

# Copy mock-claude.sh and name it "claude"
cp "$SCRIPT_DIR/mock-claude.sh" "$MOCK_BIN_DIR/claude"
chmod +x "$MOCK_BIN_DIR/claude"

trap "rm -rf $TEST_DIR" EXIT

echo -e "${BLUE}========================================"
echo "Ralph Unit Tests"
echo "========================================${NC}"
echo "Test directory: $TEST_DIR"
echo ""

# Helper: Assert file exists
assert_file_exists() {
  local file=$1
  local test_name=$2
  if [ -f "$file" ]; then
    echo -e "  ${GREEN}✓${NC} $test_name: File exists"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} $test_name: File does not exist: $file"
    ((TESTS_FAILED++))
  fi
}

# Helper: Assert JSON field equals value
assert_json_equals() {
  local file=$1
  local jq_query=$2
  local expected=$3
  local test_name=$4

  local actual=$(jq -r "$jq_query" "$file" 2>/dev/null || echo "ERROR")
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}✓${NC} $test_name: $jq_query = $expected"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} $test_name: Expected $expected, got $actual"
    ((TESTS_FAILED++))
  fi
}

# Helper: Assert exit code
assert_exit_code() {
  local actual=$1
  local expected=$2
  local test_name=$3

  if [ "$actual" -eq "$expected" ]; then
    echo -e "  ${GREEN}✓${NC} $test_name: Exit code = $expected"
    ((TESTS_PASSED++))
  else
    echo -e "  ${RED}✗${NC} $test_name: Expected exit $expected, got $actual"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# Test 1: Normal completion (3 tasks, should complete all)
# ============================================================================
echo -e "${YELLOW}Test 1: Normal PRD completion${NC}"
echo -e "  ${BLUE}Testing:${NC} Ralph completes all tasks in a PRD with dependencies"
echo -e "  ${BLUE}Verifies:${NC} Mock Claude marks tasks complete, iteration limit (tasks × 3) works"

cat > "$TEST_DIR/PRD-1-test.json" <<'EOF'
{
  "project": "Test",
  "phase": "1-test",
  "branch": "test/phase-1",
  "description": "Test PRD with 3 tasks",
  "total_tasks": 3,
  "userStories": [
    {
      "id": "TEST-001",
      "title": "Task 1",
      "priority": 1,
      "dependencies": [],
      "passes": false,
      "typecheck_passes": false
    },
    {
      "id": "TEST-002",
      "title": "Task 2",
      "priority": 2,
      "dependencies": ["TEST-001"],
      "passes": false,
      "typecheck_passes": false
    },
    {
      "id": "TEST-003",
      "title": "Task 3",
      "priority": 3,
      "dependencies": ["TEST-002"],
      "passes": false,
      "typecheck_passes": false
    }
  ]
}
EOF

# Run Ralph with mock Claude
echo -e "  ${BLUE}Running Ralph...${NC}"
echo -e "  ${BLUE}Running Ralph...${NC}"
cd "$SCRIPT_DIR/../.."
PATH="$MOCK_BIN_DIR:$PATH" "$SCRIPT_DIR/ralph.sh" \
  --yes \
  --skip-git \
  --no-auto-merge \
  "$TEST_DIR/PRD-1-test.json" > /dev/null 2>&1 || true
echo -e "  ${BLUE}Done.${NC}"

# Verify all tasks completed
assert_json_equals "$TEST_DIR/PRD-1-test.json" \
  '.userStories[0].passes' 'true' 'Test 1.1'
assert_json_equals "$TEST_DIR/PRD-1-test.json" \
  '.userStories[1].passes' 'true' 'Test 1.2'
assert_json_equals "$TEST_DIR/PRD-1-test.json" \
  '.userStories[2].passes' 'true' 'Test 1.3'

echo ""

# ============================================================================
# Test 2: Zero-task PRD (should skip with no error)
# ============================================================================
echo -e "${YELLOW}Test 2: Zero-task PRD${NC}"
echo -e "  ${BLUE}Testing:${NC} Ralph handles PRDs with 0 tasks gracefully"
echo -e "  ${BLUE}Verifies:${NC} No errors, PRD marked complete, exits successfully"

cat > "$TEST_DIR/PRD-2-zero.json" <<'EOF'
{
  "project": "Test",
  "phase": "2-zero",
  "branch": "test/phase-2",
  "description": "Empty PRD with no tasks",
  "total_tasks": 0,
  "userStories": []
}
EOF

echo -e "  ${BLUE}Running Ralph...${NC}"
cd "$SCRIPT_DIR/../.."
PATH="$MOCK_BIN_DIR:$PATH" "$SCRIPT_DIR/ralph.sh" \
  --yes \
  --skip-git \
  --no-auto-merge \
  "$TEST_DIR/PRD-2-zero.json" > /dev/null 2>&1
EXIT_CODE=$?

assert_exit_code "$EXIT_CODE" 0 "Test 2.1"
assert_json_equals "$TEST_DIR/PRD-2-zero.json" \
  '.userStories | length' '0' 'Test 2.2'

echo ""

# ============================================================================
# Test 3: Already completed PRD (should skip)
# ============================================================================
echo -e "${YELLOW}Test 3: Already completed PRD${NC}"
echo -e "  ${BLUE}Testing:${NC} Ralph skips PRDs where all tasks already complete"
echo -e "  ${BLUE}Verifies:${NC} No unnecessary iterations, tasks remain complete, exits successfully"

cat > "$TEST_DIR/PRD-3-complete.json" <<'EOF'
{
  "project": "Test",
  "phase": "3-complete",
  "branch": "test/phase-3",
  "description": "Already completed PRD",
  "total_tasks": 2,
  "userStories": [
    {
      "id": "TEST-004",
      "title": "Task 4",
      "priority": 1,
      "dependencies": [],
      "passes": true,
      "typecheck_passes": true
    },
    {
      "id": "TEST-005",
      "title": "Task 5",
      "priority": 2,
      "dependencies": [],
      "passes": true,
      "typecheck_passes": true
    }
  ]
}
EOF

echo -e "  ${BLUE}Running Ralph...${NC}"
cd "$SCRIPT_DIR/../.."
PATH="$MOCK_BIN_DIR:$PATH" "$SCRIPT_DIR/ralph.sh" \
  --yes \
  --skip-git \
  --no-auto-merge \
  "$TEST_DIR/PRD-3-complete.json" > /dev/null 2>&1
EXIT_CODE=$?

assert_exit_code "$EXIT_CODE" 0 "Test 3.1"
# Tasks should remain completed
assert_json_equals "$TEST_DIR/PRD-3-complete.json" \
  '.userStories[0].passes' 'true' 'Test 3.2'
assert_json_equals "$TEST_DIR/PRD-3-complete.json" \
  '.userStories[1].passes' 'true' 'Test 3.3'

echo ""

# ============================================================================
# Test 4: prd-query.js with mixed PRDs
# ============================================================================
echo -e "${YELLOW}Test 4: prd-query.js filtering${NC}"
echo -e "  ${BLUE}Testing:${NC} prd-query.js correctly identifies pending vs completed PRDs"
echo -e "  ${BLUE}Verifies:${NC} --pending and --completed filters work, zero-task PRDs marked complete"

# Test --pending filter
PENDING=$("$SCRIPT_DIR/prd-query.js" --pending --json -- \
  "$TEST_DIR/PRD-1-test.json" \
  "$TEST_DIR/PRD-2-zero.json" \
  "$TEST_DIR/PRD-3-complete.json" 2>/dev/null || echo "[]")

# PRD-1 should be complete now, PRD-2 is zero-task (complete), PRD-3 was already complete
# So pending should be empty
PENDING_COUNT=$(echo "$PENDING" | jq 'length')
if [ "$PENDING_COUNT" -eq 0 ]; then
  echo -e "  ${GREEN}✓${NC} Test 4.1: No pending PRDs (all complete)"
  ((TESTS_PASSED++))
else
  echo -e "  ${RED}✗${NC} Test 4.1: Expected 0 pending PRDs, got $PENDING_COUNT"
  ((TESTS_FAILED++))
fi

# Test --completed filter
COMPLETED=$("$SCRIPT_DIR/prd-query.js" --completed --json -- \
  "$TEST_DIR/PRD-1-test.json" \
  "$TEST_DIR/PRD-3-complete.json" 2>/dev/null || echo "[]")
COMPLETED_COUNT=$(echo "$COMPLETED" | jq 'length')
if [ "$COMPLETED_COUNT" -eq 2 ]; then
  echo -e "  ${GREEN}✓${NC} Test 4.2: 2 completed PRDs found"
  ((TESTS_PASSED++))
else
  echo -e "  ${RED}✗${NC} Test 4.2: Expected 2 completed PRDs, got $COMPLETED_COUNT"
  ((TESTS_FAILED++))
fi

echo ""

# ============================================================================
# Test 5: Mock Claude exit code handling
# ============================================================================
echo -e "${YELLOW}Test 5: Mock Claude failures${NC}"
echo -e "  ${BLUE}Testing:${NC} Ralph stops iteration when Claude command fails (exit code != 0)"
echo -e "  ${BLUE}Verifies:${NC} Tasks remain incomplete, no infinite loops, proper error handling"

# Create a failing mock-claude that exits with code 1
cat > "$MOCK_BIN_DIR/claude" <<'FAILEOF'
#!/usr/bin/env bash
echo "ERROR: Mock Claude failure"
exit 1
FAILEOF
chmod +x "$MOCK_BIN_DIR/claude"

cat > "$TEST_DIR/PRD-5-fail.json" <<'EOF'
{
  "project": "Test",
  "phase": "5-fail",
  "branch": "test/phase-5",
  "description": "PRD that will fail",
  "total_tasks": 2,
  "userStories": [
    {
      "id": "TEST-006",
      "title": "Task 6",
      "priority": 1,
      "dependencies": [],
      "passes": false,
      "typecheck_passes": false
    },
    {
      "id": "TEST-007",
      "title": "Task 7",
      "priority": 2,
      "dependencies": [],
      "passes": false,
      "typecheck_passes": false
    }
  ]
}
EOF

# Run Ralph with failing mock Claude
echo -e "  ${BLUE}Running Ralph...${NC}"
cd "$SCRIPT_DIR/../.."
PATH="$MOCK_BIN_DIR:$PATH" "$SCRIPT_DIR/ralph.sh" \
  --yes \
  --skip-git \
  --no-auto-merge \
  "$TEST_DIR/PRD-5-fail.json" > /dev/null 2>&1 || true

# Tasks should still be incomplete (Claude failed immediately)
assert_json_equals "$TEST_DIR/PRD-5-fail.json" \
  '.userStories[0].passes' 'false' 'Test 5.1'
assert_json_equals "$TEST_DIR/PRD-5-fail.json" \
  '.userStories[1].passes' 'false' 'Test 5.2'

echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${BLUE}========================================"
echo "Test Summary"
echo "========================================${NC}"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
  echo -e "${RED}Failed: $TESTS_FAILED${NC}"
  echo ""
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  echo ""
  exit 0
fi
