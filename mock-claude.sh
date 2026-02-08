#!/usr/bin/env bash
# Mock Claude CLI for testing Ralph
# Simulates Claude completing one task in a PRD

set -e

# Parse arguments to find the prompt and extract PRD path
PROMPT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--prompt)
      PROMPT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Extract PRD path from prompt (looks for any .json file path, with or without @ prefix)
PRD_PATH=$(echo "$PROMPT" | grep -oE '@?[^[:space:]]+\.json' | grep -E 'PRD-[0-9]+' | head -n 1)

# If still not found, try a more lenient pattern
if [ -z "$PRD_PATH" ]; then
  PRD_PATH=$(echo "$PROMPT" | grep -oE '@?/[^[:space:]]+\.json' | head -n 1)
fi

# Strip the @ prefix if present (Claude uses @ for file context)
PRD_PATH="${PRD_PATH#@}"

if [ -z "$PRD_PATH" ]; then
  echo "Mock Claude: Could not find PRD path in prompt"
  echo "Prompt was: ${PROMPT:0:200}..."
  exit 0
fi

if [ ! -f "$PRD_PATH" ]; then
  echo "Mock Claude: PRD file not found: $PRD_PATH"
  exit 0
fi

# Read PRD and find first incomplete task
INCOMPLETE_TASK=$(jq -r '
  .userStories[] |
  select(.passes == false or .typecheck_passes == false) |
  .id
' "$PRD_PATH" | head -n 1)

if [ -z "$INCOMPLETE_TASK" ]; then
  echo "Mock Claude: All tasks already complete in $PRD_PATH"
  exit 0
fi

# Mark the task as complete
jq --arg task_id "$INCOMPLETE_TASK" '
  .userStories |= map(
    if .id == $task_id then
      .passes = true |
      .typecheck_passes = true
    else
      .
    end
  )
' "$PRD_PATH" > "${PRD_PATH}.tmp" && mv "${PRD_PATH}.tmp" "$PRD_PATH"

# Simulate Claude output
echo "Mock Claude: Working on task $INCOMPLETE_TASK"
echo ""
echo "I've completed the following work:"
echo "- Read the PRD file: $PRD_PATH"
echo "- Found task $INCOMPLETE_TASK that needs completion"
echo "- Implemented the feature"
echo "- Ran tests and type checks"
echo "- Updated PRD with passes=true and typecheck_passes=true"
echo ""
echo "Task $INCOMPLETE_TASK is now complete."

exit 0
