#!/bin/bash
set -e

# Script to gather diffs from a feature branch (extracted from PRD) to master
# and copy to clipboard with a summary

# Get the ralph script directory (to skip it from submodule operations)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$1" ]; then
  echo "Usage: $0 <path-to-prd.json>"
  echo "Example: $0 PRD-1-infrastructure.json"
  exit 1
fi

PRD_PATH="$1"
BASE_BRANCH="master"

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
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  Ralph Diff Gatherer${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "PRD: ${YELLOW}${PRD_PATH}${NC}"
echo -e "Comparing: ${YELLOW}${BASE_BRANCH}${NC} → ${YELLOW}${FEATURE_BRANCH}${NC}"
echo ""

# Collect stats
declare -a REPO_STATS
TOTAL_FILES=0
TOTAL_INSERTIONS=0
TOTAL_DELETIONS=0

# Build output
OUTPUT=""
OUTPUT+="# Diff: ${FEATURE_BRANCH}\n\n"
OUTPUT+="PRD: \`${PRD_PATH}\`\n"
OUTPUT+="Comparing \`${BASE_BRANCH}\` → \`${FEATURE_BRANCH}\`\n"
OUTPUT+="Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")\n\n"

# Function to get diff for a repo
get_repo_diff() {
    local repo_path="$1"
    local repo_name="$2"

    pushd "$repo_path" > /dev/null

    # Check if feature branch exists
    if ! git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH" && \
       ! git show-ref --verify --quiet "refs/remotes/origin/$FEATURE_BRANCH"; then
        echo -e "  ${YELLOW}⚠️  No ${FEATURE_BRANCH} branch in ${repo_name}${NC}"
        popd > /dev/null
        return
    fi

    # Check if base branch exists
    if ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH" && \
       ! git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
        echo -e "  ${YELLOW}⚠️  No ${BASE_BRANCH} branch in ${repo_name}${NC}"
        popd > /dev/null
        return
    fi

    # Get the diff (base...feature shows what's in feature that's not in base)
    local diff_output
    diff_output=$(git diff "${BASE_BRANCH}...${FEATURE_BRANCH}" 2>/dev/null || git diff "origin/${BASE_BRANCH}...origin/${FEATURE_BRANCH}" 2>/dev/null || echo "")

    if [ -z "$diff_output" ]; then
        echo -e "  ${YELLOW}⚠️  No diff found for ${repo_name}${NC}"
        popd > /dev/null
        return
    fi

    # Get stats
    local stats
    stats=$(git diff --stat "${BASE_BRANCH}...${FEATURE_BRANCH}" 2>/dev/null || git diff --stat "origin/${BASE_BRANCH}...origin/${FEATURE_BRANCH}" 2>/dev/null || echo "")

    # Parse stats from last line (e.g., "10 files changed, 200 insertions(+), 50 deletions(-)")
    local files_changed insertions deletions
    files_changed=$(echo "$stats" | tail -1 | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo "0")
    insertions=$(echo "$stats" | tail -1 | grep -oE '[0-9]+ insertions?' | grep -oE '[0-9]+' || echo "0")
    deletions=$(echo "$stats" | tail -1 | grep -oE '[0-9]+ deletions?' | grep -oE '[0-9]+' || echo "0")

    # Update totals
    TOTAL_FILES=$((TOTAL_FILES + files_changed))
    TOTAL_INSERTIONS=$((TOTAL_INSERTIONS + insertions))
    TOTAL_DELETIONS=$((TOTAL_DELETIONS + deletions))

    # Store stats for summary
    REPO_STATS+=("${repo_name}|${files_changed}|${insertions}|${deletions}")

    # Print to console
    echo -e "  ${GREEN}✓${NC} ${repo_name}: ${files_changed} files, +${insertions}/-${deletions}"

    # Add to output
    OUTPUT+="\n## ${repo_name}\n\n"
    OUTPUT+="**Stats:** ${files_changed} files changed, +${insertions}/-${deletions}\n\n"
    OUTPUT+="\`\`\`diff\n"
    OUTPUT+="${diff_output}\n"
    OUTPUT+="\`\`\`\n"

    popd > /dev/null
}

# Get ralph submodule path to skip it
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --show-toplevel)"
RALPH_SUBMODULE_PATH="${SCRIPT_DIR#$REPO_ROOT/}"

# Process main repo
echo -e "${BLUE}Processing repositories...${NC}"
echo ""
get_repo_diff "." "test-app (root)"

# Process submodules (except ralph itself)
for submodule in $(git submodule foreach --quiet 'echo $sm_path'); do
    if [ -n "$submodule" ] && [ -d "$submodule" ] && [ "$submodule" != "$RALPH_SUBMODULE_PATH" ]; then
        get_repo_diff "$submodule" "$submodule"
    elif [ "$submodule" = "$RALPH_SUBMODULE_PATH" ]; then
        echo -e "  ${YELLOW}⚠️  Skipping ralph repository${NC}"
    fi
done

# Add summary header
SUMMARY="\n---\n\n## Summary\n\n"
SUMMARY+="| Repository | Files | Insertions | Deletions |\n"
SUMMARY+="|------------|-------|------------|----------|\n"

for stat in "${REPO_STATS[@]}"; do
    IFS='|' read -r name files ins del <<< "$stat"
    SUMMARY+="| ${name} | ${files} | +${ins} | -${del} |\n"
done

SUMMARY+="|------------|-------|------------|----------|\n"
SUMMARY+="| **Total** | **${TOTAL_FILES}** | **+${TOTAL_INSERTIONS}** | **-${TOTAL_DELETIONS}** |\n"

OUTPUT+="${SUMMARY}"

# Copy to clipboard
echo -e "$OUTPUT" | pbcopy

# Print summary
echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
printf "%-25s %10s %12s %12s\n" "Repository" "Files" "Insertions" "Deletions"
printf "%-25s %10s %12s %12s\n" "-------------------------" "----------" "------------" "------------"

for stat in "${REPO_STATS[@]}"; do
    IFS='|' read -r name files ins del <<< "$stat"
    printf "%-25s %10s %12s %12s\n" "$name" "$files" "+$ins" "-$del"
done

printf "%-25s %10s %12s %12s\n" "-------------------------" "----------" "------------" "------------"
printf "%-25s %10s %12s %12s\n" "TOTAL" "$TOTAL_FILES" "+$TOTAL_INSERTIONS" "-$TOTAL_DELETIONS"

echo ""
echo -e "${GREEN}✅ Diff copied to clipboard!${NC}"
echo ""

# Estimate tokens (rough: ~4 chars per token)
OUTPUT_LEN=${#OUTPUT}
ESTIMATED_TOKENS=$((OUTPUT_LEN / 4))
echo -e "📊 Output size: ${OUTPUT_LEN} characters (~${ESTIMATED_TOKENS} tokens)"
