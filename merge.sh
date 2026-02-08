#!/bin/bash
set -e

# Script to merge a feature branch (from PRD) into the ralph branch

# Get the ralph script directory (to skip it from submodule operations)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command line arguments
PRD_PATH=""
USE_CURRENT_BRANCH=false
BRANCH_NAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "Usage: $0 [OPTIONS] [path-to-prd.json]"
      echo ""
      echo "Merge a feature branch (from PRD) into the ralph branch"
      echo ""
      echo "OPTIONS:"
      echo "  --branch <name>         Use specified branch name"
      echo "  --use-current-branch    Use current branch without prompting"
      echo "  --help, -h              Show this help message"
      echo ""
      echo "If no PRD is provided, you will be prompted to use the current branch."
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

RALPH_BRANCH="ralph"
FEATURE_BRANCH=""

# If --branch is set, use that branch directly
if [ -n "$BRANCH_NAME" ]; then
  FEATURE_BRANCH="$BRANCH_NAME"
# If --use-current-branch is set, use current branch directly
elif [ "$USE_CURRENT_BRANCH" = true ]; then
  FEATURE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
# If PRD path is provided, extract branch from it
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
fi

# If no branch found, ask user if they want to use current branch
if [ -z "$FEATURE_BRANCH" ]; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  echo -n "No PRD provided. Use current branch '${CURRENT_BRANCH}'? [Y/n] "
  read -r response
  if [[ "$response" =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 1
  fi
  FEATURE_BRANCH="$CURRENT_BRANCH"
fi

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  Merge to Ralph Branch${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "PRD: ${YELLOW}${PRD_PATH}${NC}"
echo -e "Merging: ${YELLOW}${FEATURE_BRANCH}${NC} → ${YELLOW}${RALPH_BRANCH}${NC}"
echo ""

# Function to merge branch in a repo
merge_branch() {
    local repo_path="$1"
    local repo_name="$2"

    pushd "$repo_path" > /dev/null

    # Check if feature branch exists
    if ! git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH" && \
       ! git show-ref --verify --quiet "refs/remotes/origin/$FEATURE_BRANCH"; then
        echo -e "  ${YELLOW}⚠️  No ${FEATURE_BRANCH} branch in ${repo_name}, skipping${NC}"
        popd > /dev/null
        return
    fi

    # First, ensure we're on the feature branch and commit any uncommitted changes
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "$FEATURE_BRANCH" ]; then
        echo -e "  ${BLUE}Switching to ${FEATURE_BRANCH} in ${repo_name}${NC}"
        git checkout "$FEATURE_BRANCH"
    fi

    # Check for uncommitted changes and commit them
    if ! git diff-index --quiet HEAD --; then
        echo -e "  ${YELLOW}Found uncommitted changes in ${repo_name}, committing...${NC}"
        git add -A
        git commit -m "chore: Auto-commit changes before merge to ralph

Changes made during Ralph automation before merging ${FEATURE_BRANCH} → ${RALPH_BRANCH}"
        echo -e "  ${GREEN}✓${NC} Changes committed in ${repo_name}"
    fi

    # Check if ralph branch exists, create if not
    if ! git show-ref --verify --quiet "refs/heads/$RALPH_BRANCH"; then
        echo -e "  ${YELLOW}Creating ${RALPH_BRANCH} branch in ${repo_name}${NC}"
        git checkout -b "$RALPH_BRANCH"
    else
        git checkout "$RALPH_BRANCH"
    fi

    # Merge feature branch into ralph
    echo -e "  ${BLUE}Merging ${FEATURE_BRANCH} into ${RALPH_BRANCH} in ${repo_name}...${NC}"

    if git merge --no-ff "$FEATURE_BRANCH" -m "Merge ${FEATURE_BRANCH} into ${RALPH_BRANCH}"; then
        echo -e "  ${GREEN}✓${NC} ${repo_name}: merged successfully"
        echo -e "Deleting merged branch ${FEATURE_BRANCH} in ${repo_name}..."
        git branch -d "$FEATURE_BRANCH"
    else
        echo -e "  ${RED}✗${NC} ${repo_name}: merge conflict! Please resolve manually."
        popd > /dev/null
        exit 1
    fi

    popd > /dev/null
}

# Get ralph submodule path to skip it
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --show-toplevel)"
RALPH_SUBMODULE_PATH="${SCRIPT_DIR#$REPO_ROOT/}"

# Process submodules first (except ralph itself)
echo -e "${BLUE}Processing submodules first...${NC}"
echo ""
for submodule in $(git submodule foreach --quiet 'echo $sm_path'); do
    if [ -n "$submodule" ] && [ -d "$submodule" ] && [ "$submodule" != "$RALPH_SUBMODULE_PATH" ]; then
        merge_branch "$submodule" "$submodule"
    elif [ "$submodule" = "$RALPH_SUBMODULE_PATH" ]; then
        echo -e "  ${YELLOW}⚠️  Skipping ralph repository${NC}"
    fi
done

# Process main repo last
echo ""
echo -e "${BLUE}Processing main repository...${NC}"
merge_branch "." "test-app (root)"

# Commit any remaining uncommitted changes in all submodules
echo ""
echo -e "${BLUE}Checking for uncommitted changes in all submodules...${NC}"
for submodule in $(git submodule foreach --quiet 'echo $sm_path'); do
    if [ -n "$submodule" ] && [ -d "$submodule" ]; then
        pushd "$submodule" > /dev/null
        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            echo -e "  ${YELLOW}Found uncommitted changes in ${submodule}, committing...${NC}"
            git add -A
            git commit -m "chore: Auto-commit changes after merge to ralph

Post-merge cleanup for ${FEATURE_BRANCH} → ${RALPH_BRANCH}"
            echo -e "  ${GREEN}✓${NC} Changes committed in ${submodule}"
        fi
        popd > /dev/null
    fi
done

# Commit submodule pointer updates in main repo
echo ""
echo -e "${BLUE}Committing submodule pointer updates in main repo...${NC}"
if ! git diff-index --quiet HEAD --; then
    git add -A
    git commit -m "chore: Update submodule pointers after merge

Merged ${FEATURE_BRANCH} → ${RALPH_BRANCH} in all submodules"
    echo -e "${GREEN}✓${NC} Submodule pointers committed"
else
    echo -e "${YELLOW}No submodule pointer changes to commit${NC}"
fi

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Merge Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "All repos are now on the ${YELLOW}${RALPH_BRANCH}${NC} branch with ${YELLOW}${FEATURE_BRANCH}${NC} merged in."
