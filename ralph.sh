#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <path-to-prd> [max-iterations]"
  exit 1
fi

# Check for required dependencies
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is required but not installed."
  echo "Install with: brew install jq"
  exit 1
fi

PRD_PATH="$1"
PROGRESS_FILE="progress.txt"
MAX_ITERATIONS=${2:-100}

# Setup logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOGS_DIR"

# Generate session timestamp
SESSION_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Try to extract branch name from PRD for more descriptive log names
BRANCH_NAME=$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$PRD_PATH" 2>/dev/null | sed 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
if [ -n "$BRANCH_NAME" ]; then
  # Replace slashes with underscores for safe filename
  SAFE_BRANCH_NAME=$(echo "$BRANCH_NAME" | tr '/' '_')
  SESSION_LOG="${LOGS_DIR}/${SESSION_TIMESTAMP}_${SAFE_BRANCH_NAME}.log"
else
  SESSION_LOG="${LOGS_DIR}/${SESSION_TIMESTAMP}_session.log"
fi

echo "Session log: $SESSION_LOG"

# Log session header
{
  echo "========================================"
  echo "Ralph Session Started: $(date)"
  echo "PRD: $PRD_PATH"
  echo "Max Iterations: $MAX_ITERATIONS"
  echo "========================================"
  echo ""
} >> "$SESSION_LOG"

echo "Maximum number of ralph iterations: $MAX_ITERATIONS"
echo "Progress file: $PROGRESS_FILE"
echo "PRD path: $PRD_PATH"

echo "----------------------------------------"
echo "Starting ralph..."
echo "----------------------------------------"

# Check if PRD file exists
if [ ! -f "$PRD_PATH" ]; then
  echo "ERROR: PRD file not found: $PRD_PATH"
  exit 1
fi

# Check if all tasks in the PRD are already complete
# A task is complete when both "passes" and "typecheck_passes" are true
check_all_complete() {
  local prd_file="$1"

  # Count total tasks and completed tasks using jq
  local total_tasks=$(jq '.userStories | length' "$prd_file")
  local completed_tasks=$(jq '[.userStories[] | select(.passes == true and .typecheck_passes == true)] | length' "$prd_file")

  if [ "$total_tasks" -eq "$completed_tasks" ] && [ "$total_tasks" -gt 0 ]; then
    return 0  # All complete
  else
    return 1  # Not all complete
  fi
}

if check_all_complete "$PRD_PATH"; then
  echo "========================================"
  echo "All tasks in this PRD are already completed!"
  echo "========================================"
  total=$(jq '.userStories | length' "$PRD_PATH")
  echo "Total tasks: $total"
  echo "All $total tasks have passes=true and typecheck_passes=true"
  echo ""
  echo "Nothing to do. Exiting."
  exit 0
fi

# Create progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Progress Log" > "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
fi

# Extract branch name from PRD JSON
BRANCH=$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$PRD_PATH" | sed 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [ -z "$BRANCH" ]; then
  echo "ERROR: No branch field found in PRD file"
  exit 1
fi

echo "Feature branch: $BRANCH"

# Function to checkout or create branch in a repo
checkout_branch() {
  local dir="$1"
  local branch="$2"
  
  pushd "$dir" > /dev/null
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "[$dir] Switching to existing branch: $branch"
    git checkout "$branch"
  else
    echo "[$dir] Creating new branch: $branch"
    git checkout -b "$branch"
  fi
  popd > /dev/null
}

# Checkout branch in main repo
checkout_branch "." "$BRANCH"

# Get the ralph submodule path relative to repo root (to skip it from submodule operations)
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --show-toplevel)"
RALPH_SUBMODULE_PATH="${SCRIPT_DIR#$REPO_ROOT/}"

# Checkout branch in all submodules (except ralph itself)
for submodule in $(git submodule foreach --quiet 'echo $sm_path'); do
  if [ -n "$submodule" ] && [ "$submodule" != "$RALPH_SUBMODULE_PATH" ]; then
    checkout_branch "$submodule" "$BRANCH"
  elif [ "$submodule" = "$RALPH_SUBMODULE_PATH" ]; then
    echo "[$submodule] Skipping ralph repository"
  fi
done

TEMP_OUTPUT=$(mktemp)
trap "rm -f $TEMP_OUTPUT" EXIT

i=1
while [ $i -le $MAX_ITERATIONS ]; do
  echo "========================================"
  echo "Iteration $i"
  echo "========================================"
  echo "Running claude command..."

  # Log iteration header
  {
    echo ""
    echo "========================================"
    echo "Iteration $i - $(date)"
    echo "========================================"
  } >> "$SESSION_LOG"

  claude --dangerously-skip-permissions -p "@${PRD_PATH} @${PROGRESS_FILE} \
This is a monorepo with subprojects: test-backend (Cloudflare Workers) and test-mobile (React Native). \
Each subproject has its own package.json with typecheck and test scripts. \
1. Find the highest-priority feature to work on and work only on that feature. \
This should be the one YOU decide has the highest priority - not necessarily the first in the list. \
2. IMMEDIATELY append to the ${PROGRESS_FILE} file that you are STARTING work on this task (include task ID and description). \
3. Navigate to the correct subproject based on the task category (database -> test-backend, mobile -> test-mobile). \
4. Run npm run build to check types. Run npm run test if tests exist for that subproject. \
5. Update the PRD with the work that was done (set typecheck_passes to true if build passes, passes to true if tests pass or no tests exist). \
6. Append your completion status to the ${PROGRESS_FILE} file. \
Use this to leave a note for the next person working in the codebase. \
7. CODE REVIEW BEFORE COMMIT: \
   a. Gather ALL uncommitted changes for review: \
      - Run 'git status' to see changed and untracked files in main repo \
      - Run 'git diff' for unstaged changes and 'git diff --cached' for staged changes \
      - Run 'git submodule foreach git status' and 'git submodule foreach git diff' for submodule changes \
      - For new/untracked files, read their contents to include in review \
   b. Use the Task tool with model='sonnet' and subagent_type='general-purpose' to spawn a code review subagent. \
      Pass it ALL the diffs and new file contents. The review prompt should ask for: \
      - Bugs or logical errors \
      - Security vulnerabilities \
      - Performance issues \
      - Missing error handling \
      Format: 'Issues Found' (blocking), 'Suggestions' (non-blocking), 'Summary', 'Commit Message Suggestion' \
   c. If the review finds blocking issues, fix them immediately and re-run the review. \
   d. Only proceed to commit once the review returns LGTM or no blocking issues. \
8. Make a git commit of that feature from the root directory using the suggested commit message. \
ONLY WORK ON A SINGLE FEATURE. \
If, while implementing the feature, you notice the PRD is complete (all tasks pass), output <promise>COMPLETE</promise>. \
" 2>&1 | tee "$TEMP_OUTPUT" | tee -a "$SESSION_LOG"

  if grep -q "<promise>COMPLETE</promise>" "$TEMP_OUTPUT"; then
    echo "========================================"
    echo "PRD complete after $i iterations!"
    echo "========================================"
    {
      echo ""
      echo "========================================"
      echo "Session Complete: $(date)"
      echo "PRD completed after $i iterations"
      echo "========================================"
    } >> "$SESSION_LOG"
    echo "Session log saved to: $SESSION_LOG"
    exit 0
  fi

  i=$((i + 1))
done

echo "========================================"
echo "Reached maximum iterations ($MAX_ITERATIONS)"
echo "========================================"
{
  echo ""
  echo "========================================"
  echo "Session Ended: $(date)"
  echo "Reached maximum iterations ($MAX_ITERATIONS)"
  echo "========================================"
} >> "$SESSION_LOG"
echo "Session log saved to: $SESSION_LOG"
exit 0
