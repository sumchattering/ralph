#!/bin/bash
set -e

# Script to merge a feature branch (from PRD) into the ralph branch

if [ -z "$1" ]; then
  echo "Usage: $0 <path-to-prd.json>"
  echo "Example: $0 PRD-1-infrastructure.json"
  exit 1
fi

PRD_PATH="$1"
RALPH_BRANCH="ralph"

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

# Process submodules first
echo -e "${BLUE}Processing submodules first...${NC}"
echo ""
for submodule in $(git submodule foreach --quiet 'echo $sm_path'); do
    if [ -n "$submodule" ] && [ -d "$submodule" ]; then
        merge_branch "$submodule" "$submodule"
    fi
done

# Process main repo last
echo ""
echo -e "${BLUE}Processing main repository...${NC}"
merge_branch "." "test-app (root)"

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Merge Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "All repos are now on the ${YELLOW}${RALPH_BRANCH}${NC} branch with ${YELLOW}${FEATURE_BRANCH}${NC} merged in."
