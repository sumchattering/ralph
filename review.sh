#!/bin/bash
set -e

# Script to gather diff and optionally send to Codex for review

# Get the ralph script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Parse command line arguments
BRANCH_NAME=""
USE_CURRENT_BRANCH=false
PRD_PATH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "Usage: $0 [OPTIONS] [path-to-prd.json]"
      echo ""
      echo "Gather diff from a branch and optionally send to Codex for review"
      echo ""
      echo "OPTIONS:"
      echo "  --branch <name>         Use specified branch name"
      echo "  --use-current-branch    Use current branch without prompting"
      echo "  --help, -h              Show this help message"
      echo ""
      echo "This script will:"
      echo "  1. Check if Codex CLI is installed"
      echo "  2. Run diff.sh to gather diffs"
      echo "  3. Ask if you want to send the diff to Codex for review"
      echo ""
      echo "Example: $0 PRD-1-infrastructure.json"
      echo "Example: $0 --branch feature/my-feature"
      echo "Example: $0 --use-current-branch"
      exit 0
      ;;
    --branch)
      BRANCH_NAME="$2"
      shift 2
      ;;
    --use-current-branch)
      USE_CURRENT_BRANCH=true
      shift
      ;;
    *)
      if [ -z "$PRD_PATH" ]; then
        PRD_PATH="$1"
      else
        echo "ERROR: Multiple PRD paths provided"
        echo "Use --help for usage information"
        exit 1
      fi
      shift
      ;;
  esac
done

# Determine the branch to use
FEATURE_BRANCH=""

# Priority: --branch > --use-current-branch > PRD file > prompt user
if [ -n "$BRANCH_NAME" ]; then
  FEATURE_BRANCH="$BRANCH_NAME"
elif [ "$USE_CURRENT_BRANCH" = true ]; then
  FEATURE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
elif [ -n "$PRD_PATH" ]; then
  # Check if PRD file exists
  if [ ! -f "$PRD_PATH" ]; then
    echo "ERROR: PRD file not found: $PRD_PATH"
    exit 1
  fi

  # Extract branch name from PRD JSON
  FEATURE_BRANCH=$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$PRD_PATH" | sed 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

  if [ -z "$FEATURE_BRANCH" ]; then
    echo "ERROR: No branch field found in PRD file"
    exit 1
  fi
else
  # Ask user if they want to use current branch
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  echo -n "No branch specified. Use current branch '${CURRENT_BRANCH}'? [Y/n] "
  read -r response
  if [[ "$response" =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 1
  fi
  FEATURE_BRANCH="$CURRENT_BRANCH"
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  Ralph Code Review${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "Branch: ${YELLOW}${FEATURE_BRANCH}${NC}"
echo ""

# Check if Codex CLI is installed
if ! command -v codex &> /dev/null; then
  echo -e "${RED}ERROR: Codex CLI is not installed or not in PATH${NC}"
  echo ""
  echo "Please install the Codex CLI and make sure it's authenticated."
  echo "Visit: https://github.com/openai/codex-cli for installation instructions"
  exit 1
fi

echo -e "${GREEN}✓${NC} Codex CLI found"
echo ""

# Run diff.sh to gather the diff
echo -e "${BLUE}Gathering diff from branch '${FEATURE_BRANCH}'...${NC}"
echo ""

"${SCRIPT_DIR}/diff.sh" --branch "$FEATURE_BRANCH"

echo ""

# Ask user if they want to send to Codex for review
echo -n -e "${YELLOW}Do you want to send this diff to Codex for review? [y/N] ${NC}"
read -r response

if [[ "$response" =~ ^[Yy]$ ]]; then
  echo ""
  echo -e "${BLUE}Sending diff to Codex for review...${NC}"
  echo ""

  # Get diff from clipboard and send to Codex
  DIFF_CONTENT=$(pbpaste)

  # Send to Codex for review
  echo "$DIFF_CONTENT" | codex "Please review this code diff. Look for potential bugs, security issues, code style problems, and suggest improvements. Here is the diff:"

  echo ""
  echo -e "${GREEN}✓ Review complete${NC}"
else
  echo ""
  echo -e "${YELLOW}Review skipped. Diff is still in your clipboard.${NC}"
fi
