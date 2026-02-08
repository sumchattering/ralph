#!/bin/bash
set -e

# --- Usage ---
usage() {
  echo "Usage: $0 [OPTIONS] <prd1> [prd2] ..."
  echo ""
  echo "Process one or more PRDs sequentially. Each PRD is worked on until"
  echo "all its tasks are complete, then the next PRD begins."
  echo "Already-completed PRDs are filtered out automatically."
  echo ""
  echo "OPTIONS:"
  echo "  --max-iterations N    Maximum iterations per PRD (default: task count × 3)"
  echo "  --auto-merge          Force auto-merge (default for multiple PRDs)"
  echo "  --no-auto-merge       Disable auto-merge between PRDs"
  echo "  --yes, -y             Skip confirmation prompt"
  echo "  --help, -h            Show this help message"
  echo ""
  echo "EXAMPLES:"
  echo "  $0 PRD-1-database.json"
  echo "  $0 PRD-1-database.json 50                    # backward compat (override max iterations)"
  echo "  $0 PRD-1-db.json PRD-2-auth.json PRD-3-api.json"
  echo "  $0 --max-iterations 30 --auto-merge PRD-*.json"
  echo ""
  echo "EXIT CODES:"
  echo "  0  All PRDs completed (or already were)"
  echo "  1  General error (missing file, bad arguments, etc.)"
  echo "  2  Usage/rate limit reached — graceful shutdown"
  echo "  3  Max iterations exceeded — PRD failed to complete"
}

# --- Argument Parsing ---
MAX_ITERATIONS=""
AUTO_MERGE=""
AUTO_CONFIRM=false
PRD_PATHS=()

# Backward compatibility: ./ralph.sh prd.json 50
if [ $# -eq 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
  PRD_PATHS=("$1")
  MAX_ITERATIONS="$2"
else
  while [[ $# -gt 0 ]]; do
    case $1 in
      --max-iterations)
        MAX_ITERATIONS="$2"
        shift 2
        ;;
      --auto-merge)
        AUTO_MERGE=true
        shift
        ;;
      --no-auto-merge)
        AUTO_MERGE=false
        shift
        ;;
      --yes|-y)
        AUTO_CONFIRM=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      -*)
        echo "ERROR: Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
      *)
        PRD_PATHS+=("$1")
        shift
        ;;
    esac
  done
fi

if [ ${#PRD_PATHS[@]} -eq 0 ]; then
  usage
  exit 1
fi

# --- Dependency Check ---
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is required but not installed."
  echo "Install with: brew install jq"
  exit 1
fi

# Script directory (needed early for filter-prds.js)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Helper Functions ---

# Attempt to repair malformed JSON using Claude sonnet subagent
repair_prd_json() {
  local prd_file="$1"
  local backup_file="${prd_file}.backup.$(date +%s)"

  echo "WARNING: PRD file appears to be malformed JSON"
  echo "Creating backup: $backup_file"
  cp "$prd_file" "$backup_file"

  echo "Attempting to repair JSON using Claude sonnet subagent..."

  # Use Claude with Task tool to spawn sonnet subagent for JSON repair
  claude -p "Use the Task tool with model='sonnet' and subagent_type='general-purpose' to spawn a JSON repair subagent.

Pass this prompt to the subagent:

'The following JSON file is malformed: $prd_file

Your task:
1. Read the file
2. Fix any JSON syntax errors (missing brackets, quotes, commas, etc.)
3. Preserve ALL existing data - do not delete or modify any task data
4. Preserve all task completion states (passes, typecheck_passes fields)
5. Write the repaired JSON back to the same file

If the file is too corrupted to repair, respond with ERROR and explain why.'" 2>&1

  # Check if repair worked
  if jq empty "$prd_file" 2>/dev/null; then
    echo "✓ JSON successfully repaired"
    echo "Backup saved to: $backup_file"
    return 0
  else
    echo "✗ JSON repair failed"
    echo "Restoring from backup..."
    cp "$backup_file" "$prd_file"
    return 1
  fi
}

# Check if all tasks in a PRD are complete (used for runtime checks in main loop)
check_all_complete() {
  local prd_file="$1"

  # Validate JSON first - attempt repair if malformed
  if ! jq empty "$prd_file" 2>/dev/null; then
    echo "ERROR: PRD file is not valid JSON: $prd_file" >&2

    # Attempt automatic repair
    if repair_prd_json "$prd_file"; then
      echo "JSON repaired successfully, continuing..."
    else
      echo "CRITICAL: Could not repair JSON automatically" >&2
      echo "Manual intervention required" >&2
      return 1
    fi
  fi

  # Get counts
  local total_tasks=$(jq '.userStories | length' "$prd_file" 2>/dev/null)
  local completed_tasks=$(jq '[.userStories[] | select(.passes == true and .typecheck_passes == true)] | length' "$prd_file" 2>/dev/null)

  # Validate numeric output
  if ! [[ "$total_tasks" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid task count in PRD: total_tasks='$total_tasks'" >&2
    return 1
  fi

  if ! [[ "$completed_tasks" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid completed count in PRD: completed_tasks='$completed_tasks'" >&2
    return 1
  fi

  # Handle empty PRDs
  if [ "$total_tasks" -eq 0 ]; then
    echo "WARNING: PRD has 0 tasks, treating as complete" >&2
    return 0
  fi

  # Check completion
  if [ "$total_tasks" -eq "$completed_tasks" ]; then
    return 0
  fi

  return 1
}

# Checkout or create branch in a repo
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

# Checkout branch in main repo and all submodules
checkout_all() {
  local branch="$1"
  checkout_branch "." "$branch"
  for submodule in $(git submodule foreach --quiet 'echo $sm_path'); do
    if [ -n "$submodule" ] && [ "$submodule" != "$RALPH_SUBMODULE_PATH" ]; then
      checkout_branch "$submodule" "$branch"
    elif [ "$submodule" = "$RALPH_SUBMODULE_PATH" ]; then
      echo "[$submodule] Skipping ralph repository"
    fi
  done
}

# Check if Claude CLI output indicates a usage/rate limit error
check_usage_limit() {
  local output_file="$1"
  # More specific patterns to avoid false positives
  # Match actual Claude API errors, not narrative text
  if grep -qiE "(\brate.?limit\b|\bquota.?exceeded\b|\boverloaded\b|\btoo.?many.?requests\b|\bcredit.?exhausted\b|\bapi.?limit\b|\bupgrade.?account\b|\bpayment.?required\b)" "$output_file"; then
    return 0  # Usage limit detected
  fi
  return 1
}

# Graceful shutdown on usage limit
graceful_shutdown() {
  local prd="$1"
  local prd_num="$2"
  local iteration="$3"

  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "  USAGE LIMIT DETECTED — SHUTTING DOWN"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo ""
  echo "Stopped during PRD $prd_num/$TOTAL_PRDS: $prd"
  echo "Iteration: $iteration"
  echo ""
  echo "Completed PRDs: $COMPLETED_PRDS/$TOTAL_PRDS"
  echo "Remaining PRDs:"
  for ((r=prd_num-1; r<TOTAL_PRDS; r++)); do
    echo "  - ${PRD_PATHS[$r]}"
  done
  echo ""
  echo "Resume by re-running with the remaining PRDs."

  {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "USAGE LIMIT DETECTED — GRACEFUL SHUTDOWN"
    echo "Time: $(date)"
    echo "Stopped during PRD $prd_num/$TOTAL_PRDS: $prd"
    echo "Iteration: $iteration"
    echo "Completed PRDs: $COMPLETED_PRDS/$TOTAL_PRDS"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  } >> "$SESSION_LOG"

  echo "Session log saved to: $SESSION_LOG"
  exit 2
}

# --- Validate all PRD files upfront ---
for prd in "${PRD_PATHS[@]}"; do
  if [ ! -f "$prd" ]; then
    echo "ERROR: PRD file not found: $prd"
    exit 1
  fi
  branch_check=$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$prd" 2>/dev/null | head -1)
  if [ -z "$branch_check" ]; then
    echo "ERROR: No branch field found in PRD: $prd"
    exit 1
  fi
done

# --- Filter PRDs using filter-prds.js ---

# Show status overview of all input PRDs
node "$SCRIPT_DIR/filter-prds.js" "${PRD_PATHS[@]}"

# Get only pending (incomplete) PRD paths
ORIGINAL_PRD_COUNT=${#PRD_PATHS[@]}
set +e
PENDING_OUTPUT=$(node "$SCRIPT_DIR/filter-prds.js" --pending "${PRD_PATHS[@]}" 2>/dev/null)
FILTER_EXIT=$?
set -e

if [ $FILTER_EXIT -ne 0 ]; then
  echo ""
  echo "========================================"
  echo "All ${ORIGINAL_PRD_COUNT} PRD(s) are already completed. Nothing to do."
  echo "========================================"
  exit 0
fi

# Replace PRD_PATHS with only the pending ones
PRD_PATHS=()
while IFS= read -r line; do
  [ -n "$line" ] && PRD_PATHS+=("$line")
done <<< "$PENDING_OUTPUT"

TOTAL_PRDS=${#PRD_PATHS[@]}
SKIPPED_PRDS_COUNT=$((ORIGINAL_PRD_COUNT - TOTAL_PRDS))

# Auto-merge defaults to on for multiple PRDs
if [ -z "$AUTO_MERGE" ]; then
  if [ $TOTAL_PRDS -gt 1 ]; then
    AUTO_MERGE=true
  else
    AUTO_MERGE=false
  fi
fi

# --- Execution Plan & Confirmation ---
echo ""
echo "========================================"
echo "  Execution Plan"
echo "========================================"
echo ""
echo "Will process $TOTAL_PRDS PRD(s) in order:"
for prd_idx in "${!PRD_PATHS[@]}"; do
  prd="${PRD_PATHS[$prd_idx]}"
  total=$(jq '.userStories | length' "$prd")
  done_count=$(jq '[.userStories[] | select(.passes == true and .typecheck_passes == true)] | length' "$prd")
  remaining=$((total - done_count))
  if [ -n "$MAX_ITERATIONS" ]; then
    prd_limit=$MAX_ITERATIONS
  else
    prd_limit=$((total * 3))
  fi
  echo "  $((prd_idx + 1)). $(basename "$prd" .json) — $remaining tasks remaining ($done_count/$total done, max $prd_limit iterations)"
done
echo ""
if [ -n "$MAX_ITERATIONS" ]; then
  echo "Max iterations per PRD: $MAX_ITERATIONS (override)"
else
  echo "Max iterations per PRD: auto (task count × 3)"
fi
if [ "$AUTO_MERGE" = true ] && [ $TOTAL_PRDS -gt 1 ]; then
  echo "Auto-merge: enabled (each PRD's branch will be merged before starting the next)"
  echo "  Disable with --no-auto-merge"
fi
echo ""

if [ "$AUTO_CONFIRM" != true ]; then
  read -p "Press Enter to start, or Ctrl+C to cancel... "
  echo ""
fi

# --- Setup ---
PROGRESS_FILE="progress.txt"
LOGS_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOGS_DIR"

SESSION_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SESSION_LOG="${LOGS_DIR}/${SESSION_TIMESTAMP}_session.log"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --show-toplevel)"
RALPH_SUBMODULE_PATH="${SCRIPT_DIR#$REPO_ROOT/}"

TEMP_OUTPUT=$(mktemp)

# Graceful shutdown flag
GRACEFUL_SHUTDOWN=false

# Cleanup function
cleanup_temp() {
  rm -f "$TEMP_OUTPUT" 2>/dev/null || true
}

# Graceful shutdown handler for Ctrl+C
handle_interrupt() {
  echo ""
  echo "========================================"
  echo "  Ctrl+C detected!"
  echo "========================================"
  echo ""
  echo "Will stop gracefully after current task completes..."
  echo "Press Ctrl+C again to force immediate exit."
  echo ""
  GRACEFUL_SHUTDOWN=true

  # Second Ctrl+C forces immediate exit
  trap 'echo "Force exit!"; cleanup_temp; exit 130' INT
}

# Set up traps
trap cleanup_temp EXIT
trap handle_interrupt INT
trap cleanup_temp TERM

# Log session header
{
  echo "========================================"
  echo "Ralph Session Started: $(date)"
  echo "Input PRDs: $ORIGINAL_PRD_COUNT"
  echo "Skipped (already complete): $SKIPPED_PRDS_COUNT"
  echo "Pending PRDs: $TOTAL_PRDS"
  for prd in "${PRD_PATHS[@]}"; do
    echo "  - $prd"
  done
  echo "Max Iterations per PRD: ${MAX_ITERATIONS:-auto (tasks × 3)}"
  echo "Auto-merge: $AUTO_MERGE"
  echo "========================================"
  echo ""
} >> "$SESSION_LOG"

# Create progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Progress Log" > "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
fi

# --- Main Loop: Process Each PRD ---
COMPLETED_PRDS=0

for prd_idx in "${!PRD_PATHS[@]}"; do
  PRD_PATH="${PRD_PATHS[$prd_idx]}"
  PRD_NUM=$((prd_idx + 1))

  echo ""
  echo "########################################"
  echo "  PRD $PRD_NUM/$TOTAL_PRDS: $PRD_PATH"
  echo "########################################"

  {
    echo ""
    echo "########################################"
    echo "PRD $PRD_NUM/$TOTAL_PRDS: $PRD_PATH"
    echo "Started: $(date)"
    echo "########################################"
  } >> "$SESSION_LOG"

  # Safety check — PRD could have been completed by a previous PRD's work
  if check_all_complete "$PRD_PATH"; then
    total=$(jq '.userStories | length' "$PRD_PATH")
    echo "All $total tasks already completed — skipping."
    {
      echo "  All $total tasks already completed — skipped."
    } >> "$SESSION_LOG"
    COMPLETED_PRDS=$((COMPLETED_PRDS + 1))
    continue
  fi

  # Extract and checkout branch
  BRANCH=$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$PRD_PATH" | sed 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  echo "Feature branch: $BRANCH"
  checkout_all "$BRANCH"

  # Calculate max iterations for this PRD
  if [ -n "$MAX_ITERATIONS" ]; then
    PRD_MAX_ITERATIONS=$MAX_ITERATIONS
  else
    TASK_COUNT=$(jq '.userStories | length' "$PRD_PATH" 2>/dev/null)

    # Validate task count
    if ! [[ "$TASK_COUNT" =~ ^[0-9]+$ ]]; then
      echo "ERROR: Could not determine task count for $PRD_PATH"
      echo "jq output was: $TASK_COUNT"
      exit 1
    fi

    # Handle empty PRDs
    if [ "$TASK_COUNT" -eq 0 ]; then
      echo "WARNING: PRD has 0 tasks. Marking as complete and skipping."
      {
        echo "PRD $PRD_NUM has 0 tasks - skipped"
      } >> "$SESSION_LOG"
      COMPLETED_PRDS=$((COMPLETED_PRDS + 1))
      continue
    fi

    PRD_MAX_ITERATIONS=$((TASK_COUNT * 3))
  fi
  echo "Max iterations for this PRD: $PRD_MAX_ITERATIONS"

  # --- Inner Loop: Iterate on this PRD ---
  i=1
  PRD_DONE=false
  while [ $i -le $PRD_MAX_ITERATIONS ]; do
    echo "========================================"
    echo "PRD $PRD_NUM | Iteration $i"
    echo "========================================"
    echo "Running claude command..."

    {
      echo ""
      echo "========================================"
      echo "PRD $PRD_NUM | Iteration $i - $(date)"
      echo "========================================"
    } >> "$SESSION_LOG"

    # Run Claude — capture output for inspection
    # Use set +e so a non-zero exit from claude doesn't kill the script
    set +e
    claude --dangerously-skip-permissions -p "@${PRD_PATH} @${PROGRESS_FILE} \
This is a monorepo with subprojects: test-backend (Cloudflare Workers) and test-mobile (React Native). \
Each subproject has its own package.json with typecheck and test scripts. \
1. Find the next task to work on using these rules IN ORDER: \
   a. ONLY consider tasks where passes=false or typecheck_passes=false (incomplete tasks) \
   b. ONLY consider tasks where ALL dependencies are complete (dependencies have passes=true AND typecheck_passes=true) \
   c. Among eligible tasks, pick the one with the LOWEST priority number (priority 1 is highest) \
   d. If multiple tasks have the same priority number, pick the first one in the list \

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
ONLY WORK ON A SINGLE FEATURE PER ITERATION. \
After completing your task, the script will automatically check if all tasks in the PRD are complete. \
" 2>&1 | tee "$TEMP_OUTPUT" | tee -a "$SESSION_LOG"
    CLAUDE_EXIT=${PIPESTATUS[0]}
    set -e

    # Check if claude command failed
    if [ $CLAUDE_EXIT -ne 0 ]; then
      echo "ERROR: claude command failed with exit code $CLAUDE_EXIT"
      echo "PRD cannot progress. Stopping iteration loop."
      {
        echo ""
        echo "ERROR: Claude command failed at iteration $i with exit code $CLAUDE_EXIT"
        echo "Time: $(date)"
      } >> "$SESSION_LOG"
      PRD_DONE=false
      break
    fi

    # Check for usage/rate limit errors
    if check_usage_limit "$TEMP_OUTPUT"; then
      graceful_shutdown "$PRD_PATH" "$PRD_NUM" "$i"
    fi

    # Check PRD completion status via JSON (authoritative source)
    if check_all_complete "$PRD_PATH"; then
      echo "========================================"
      echo "✅ PRD $PRD_NUM/$TOTAL_PRDS COMPLETE after $i iterations!"
      echo "All tasks have passes=true and typecheck_passes=true"
      echo "========================================"
      {
        echo ""
        echo "PRD $PRD_NUM/$TOTAL_PRDS complete after $i iterations"
        echo "Time: $(date)"
      } >> "$SESSION_LOG"
      PRD_DONE=true
      break
    fi

    # Check for graceful shutdown request
    if [ "$GRACEFUL_SHUTDOWN" = true ]; then
      echo ""
      echo "========================================"
      echo "  Graceful Shutdown Requested"
      echo "========================================"
      echo ""
      echo "Stopping after iteration $i"
      echo "PRD $PRD_NUM/$TOTAL_PRDS was not completed"
      echo "Completed iterations: $i / $PRD_MAX_ITERATIONS"
      echo ""
      echo "To resume, run ralph again with remaining PRDs:"
      for ((r=prd_idx; r<TOTAL_PRDS; r++)); do
        echo "  - ${PRD_PATHS[$r]}"
      done
      echo ""
      {
        echo ""
        echo "Graceful shutdown at PRD $PRD_NUM, iteration $i"
        echo "Time: $(date)"
      } >> "$SESSION_LOG"
      echo "Session log saved to: $SESSION_LOG"
      exit 130
    fi

    i=$((i + 1))
  done

  if [ "$PRD_DONE" = true ]; then
    COMPLETED_PRDS=$((COMPLETED_PRDS + 1))

    # Auto-merge if enabled and there are more PRDs to process
    if [ "$AUTO_MERGE" = true ] && [ $PRD_NUM -lt $TOTAL_PRDS ]; then
      echo "----------------------------------------"
      echo "Auto-merging branch: $BRANCH"
      echo "----------------------------------------"
      {
        echo ""
        echo "Auto-merging branch: $BRANCH"
        echo "Time: $(date)"
      } >> "$SESSION_LOG"

      if "${SCRIPT_DIR}/merge.sh" "$PRD_PATH" 2>&1 | tee -a "$SESSION_LOG"; then
        echo "Merge successful."
      else
        echo ""
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  CRITICAL: AUTO-MERGE FAILED"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo ""
        echo "PRD: $PRD_PATH"
        echo "Repository is in merge-conflict state. Cannot continue to next PRD."
        echo ""
        echo "To resolve:"
        echo "  1. Run 'git status' in each submodule to see conflicts"
        echo "  2. Resolve conflicts manually"
        echo "  3. Run 'git add .' and 'git commit' in each conflicted repo"
        echo "  4. Re-run Ralph with remaining PRDs"
        echo ""
        {
          echo ""
          echo "CRITICAL ERROR: Auto-merge failed for PRD $PRD_NUM: $PRD_PATH"
          echo "Repository left in conflict state - cannot continue"
          echo "Time: $(date)"
        } >> "$SESSION_LOG"
        echo "Session log saved to: $SESSION_LOG"
        exit 1
      fi
    fi
  else
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  ERROR: MAX ITERATIONS EXCEEDED"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo "PRD $PRD_NUM/$TOTAL_PRDS failed to complete within $PRD_MAX_ITERATIONS iterations:"
    echo "  $PRD_PATH"
    echo ""
    echo "Completed PRDs: $COMPLETED_PRDS/$TOTAL_PRDS"
    if [ $PRD_NUM -lt $TOTAL_PRDS ]; then
      echo "Remaining PRDs:"
      for ((r=prd_idx; r<TOTAL_PRDS; r++)); do
        echo "  - ${PRD_PATHS[$r]}"
      done
    fi
    echo ""
    echo "You can retry with more iterations:"
    echo "  $0 --max-iterations $((PRD_MAX_ITERATIONS * 2)) ${PRD_PATHS[*]:$prd_idx}"

    {
      echo ""
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "ERROR: MAX ITERATIONS EXCEEDED"
      echo "Time: $(date)"
      echo "PRD $PRD_NUM/$TOTAL_PRDS: $PRD_PATH"
      echo "Max iterations: $PRD_MAX_ITERATIONS"
      echo "Completed PRDs: $COMPLETED_PRDS/$TOTAL_PRDS"
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    } >> "$SESSION_LOG"

    echo "Session log saved to: $SESSION_LOG"
    exit 3
  fi
done

# --- Session Summary ---
echo ""
echo "========================================"
echo "  Ralph Session Complete"
echo "========================================"
echo "Completed: $COMPLETED_PRDS/$TOTAL_PRDS pending PRD(s)"
if [ $SKIPPED_PRDS_COUNT -gt 0 ]; then
  echo "Skipped (already done): $SKIPPED_PRDS_COUNT"
fi

# Show final status of processed PRDs
node "$SCRIPT_DIR/filter-prds.js" "${PRD_PATHS[@]}"

{
  echo ""
  echo "========================================"
  echo "Ralph Session Complete: $(date)"
  echo "Completed: $COMPLETED_PRDS/$TOTAL_PRDS pending PRD(s)"
  echo "Skipped (already done): $SKIPPED_PRDS_COUNT"
  echo "========================================"
} >> "$SESSION_LOG"

echo "Session log saved to: $SESSION_LOG"
exit 0
