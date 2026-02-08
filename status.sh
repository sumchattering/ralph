#!/bin/bash
#
# status.sh — Unified PRD status and query tool
#
# Shows PRD completion status or queries task details.
# Accepts: directories, individual files, wildcards, or auto-discovers PRDs.
#
# USAGE:
#   status.sh [options] [path...]
#
#   Path can be:
#     - A directory containing PRD-*.json files
#     - One or more .json files (wildcards work)
#     - Omitted to auto-discover from test-spec/*/PRD/
#
# COMMANDS:
#   (default)             Show PRD-level completion status (progress bars)
#   --status              Show task-level summary statistics
#   --list                List all tasks (supports filters below)
#   --show <task-id>      Show detailed info for a task
#   --search <query>      Search tasks by keyword
#   --deps <task-id>      Show dependency tree
#
# FILTERS (with --list):
#   --completed           Only completed tasks
#   --pending             Only pending tasks
#   --phase <n>           Filter by phase number
#   --category <name>     Filter by category
#   --priority <n>        Filter by priority
#   --complexity <level>  Filter by complexity (low/medium/high)
#
# OPTIONS:
#   --json                Output in JSON format
#   --help, -h            Show this help
#
# EXAMPLES:
#   status.sh                                          # auto-discover all PRDs
#   status.sh ./test-spec/naksh/PRD/                   # all PRDs in directory
#   status.sh ./test-spec/naksh/PRD/PRD-1*.json        # wildcard
#   status.sh --list --pending ./test-spec/naksh/PRD/  # pending tasks
#   status.sh --show NKS-001 ./test-spec/naksh/PRD/    # task detail
#   status.sh --search chat ./test-spec/naksh/PRD/     # search

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================================
# Parse arguments: separate flags/commands from file/dir paths
# ============================================================================

FLAGS=()
PATHS=()

show_help() {
  # Extract help from this script's header comments
  sed -n '3,/^$/{ s/^# \?//; p; }' "$0"
  exit 0
}

i=0
args=("$@")
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  case "$arg" in
    --help|-h)
      show_help
      ;;
    --status|--list|--json|--completed|--pending|--task-completed|--task-pending)
      FLAGS+=("$arg")
      ;;
    --show|--search|--deps|--phase|--category|--priority|--complexity)
      FLAGS+=("$arg")
      # Next arg is the value for this flag
      i=$((i + 1))
      if [ $i -lt ${#args[@]} ]; then
        FLAGS+=("${args[$i]}")
      else
        echo "Error: $arg requires a value" >&2
        exit 1
      fi
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      PATHS+=("$arg")
      ;;
  esac
  i=$((i + 1))
done

# ============================================================================
# Resolve paths to PRD files
# ============================================================================

PRD_FILES=()

resolve_dir() {
  local dir="$1"
  local found=0
  for f in "$dir"/PRD-*.json; do
    if [ -f "$f" ]; then
      PRD_FILES+=("$f")
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "Warning: No PRD-*.json files found in $dir" >&2
  fi
}

if [ ${#PATHS[@]} -eq 0 ]; then
  # Auto-discover: look for test-spec/*/PRD/ directories
  found_any=false
  for prd_dir in "$REPO_ROOT"/test-spec/*/PRD; do
    if [ -d "$prd_dir" ]; then
      resolve_dir "$prd_dir"
      found_any=true
    fi
  done
  if [ "$found_any" = false ]; then
    echo "Error: No PRD directories found in test-spec/*/PRD/" >&2
    echo "Specify a path explicitly, e.g.: status.sh ./test-spec/naksh/PRD/" >&2
    exit 1
  fi
else
  for p in "${PATHS[@]}"; do
    if [ -d "$p" ]; then
      resolve_dir "$p"
    elif [ -f "$p" ]; then
      PRD_FILES+=("$p")
    else
      echo "Warning: $p is not a file or directory, skipping" >&2
    fi
  done
fi

if [ ${#PRD_FILES[@]} -eq 0 ]; then
  echo "Error: No PRD files found" >&2
  exit 1
fi

# ============================================================================
# Delegate to prd-query.js (single source of truth for all PRD operations)
# ============================================================================

exec node "$SCRIPT_DIR/prd-query.js" ${FLAGS[@]+"${FLAGS[@]}"} -- "${PRD_FILES[@]}"
