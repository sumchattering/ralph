#!/bin/bash
set -e

# Script to gather diffs from a feature branch (extracted from PRD) to master
# and copy to clipboard with a summary

# Get the ralph script directory (to skip it from submodule operations)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command line arguments
VERBOSE=false
PRD_PATH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "Usage: $0 [OPTIONS] <path-to-prd.json>"
      echo ""
      echo "Gather diffs from a feature branch (extracted from PRD) to master"
      echo "and copy to clipboard with a summary"
      echo ""
      echo "OPTIONS:"
      echo "  --verbose, -v    Print list of changed files to console"
      echo "  --help, -h       Show this help message"
      echo ""
      echo "Example: $0 --verbose PRD-1-infrastructure.json"
      exit 0
      ;;
    --verbose|-v)
      VERBOSE=true
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

if [ -z "$PRD_PATH" ]; then
  echo "ERROR: PRD path is required"
  echo "Use --help for usage information"
  exit 1
fi
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
declare -a EXCLUDED_FILES
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

    # Separate JSON files from other files
    local json_files non_json_files
    json_files=$(echo "$stats" | sed '$d' | grep '\.json[[:space:]]*|' || echo "")
    non_json_files=$(echo "$stats" | sed '$d' | grep -v '\.json[[:space:]]*|' || echo "")

    # Add JSON files to excluded list if any exist
    if [ -n "$json_files" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                EXCLUDED_FILES+=("${repo_name}: ${line}")
            fi
        done <<< "$json_files"
    fi

    # Recreate stats excluding JSON files
    if [ -n "$non_json_files" ]; then
        # Get the summary line from the original stats
        local summary_line
        summary_line=$(echo "$stats" | tail -1)

        # Count non-JSON files
        local non_json_count
        non_json_count=$(echo "$non_json_files" | grep -c '^' || echo "0")

        if [ "$non_json_count" -gt 0 ]; then
            # Recalculate insertions and deletions from non-JSON files only
            local filtered_insertions filtered_deletions
            filtered_insertions=$(echo "$non_json_files" | awk -F'|' '{gsub(/[-+]/, "", $2); sum += $2} END {print sum+0}' || echo "0")
            filtered_deletions=$(echo "$non_json_files" | awk -F'|' '{
                split($2, parts, "-")
                if (length(parts) > 1) {
                    sum += parts[2]
                }
            } END {print sum+0}' || echo "0")

            # Update summary line to reflect filtered counts
            summary_line="${non_json_count} files changed, ${filtered_insertions} insertions(+), ${filtered_deletions} deletions(-)"
            stats="${non_json_files}\n${summary_line}"
        else
            stats="${summary_line}"
        fi
    fi

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

    # Print file list if verbose
    if [ "$VERBOSE" = true ] && [ "$files_changed" -gt 0 ]; then
        echo -e "    ${BLUE}Files changed:${NC}"
        # Get list of changed files with their change stats (excluding the summary line)
        local file_list
        file_list=$(echo "$stats" | sed '$d')
        if [ -n "$file_list" ]; then
            echo "$file_list" | while IFS= read -r line; do
                echo -e "    ${line}"
            done
        fi
    fi

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

# Add excluded files section if verbose and there are excluded files
if [ "$VERBOSE" = true ] && [ ${#EXCLUDED_FILES[@]} -gt 0 ]; then
    OUTPUT+="\n## Excluded Files (JSON)\n\n"
    OUTPUT+="The following JSON files were excluded from the diff:\n\n"
    for excluded_file in "${EXCLUDED_FILES[@]}"; do
        OUTPUT+="\`\`\`\n${excluded_file}\n\`\`\`\n"
    done

    # Also print to console
    echo ""
    echo -e "${YELLOW}======================================${NC}"
    echo -e "${YELLOW}  Excluded Files (JSON)${NC}"
    echo -e "${YELLOW}======================================${NC}"
    echo ""
    echo "The following JSON files were excluded from the diff:"
    echo ""
    for excluded_file in "${EXCLUDED_FILES[@]}"; do
        echo -e "  ${excluded_file}"
    done
    echo ""
fi

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
