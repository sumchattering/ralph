#!/bin/bash
set -e

# Script to gather diffs from a feature branch (extracted from PRD) to master
# and copy to clipboard with a summary

# Get the ralph script directory (to skip it from submodule operations)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command line arguments
VERBOSE=false
PRD_PATH=""
USE_CURRENT_BRANCH=false
BRANCH_NAME=""
declare -a EXCLUDE_PATTERNS

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "Usage: $0 [OPTIONS] [path-to-prd.json]"
      echo ""
      echo "Gather diffs from a feature branch (extracted from PRD) to master"
      echo "and copy to clipboard with a summary"
      echo ""
      echo "OPTIONS:"
      echo "  --verbose, -v           Print list of changed files to console"
      echo "  --branch <name>         Use specified branch name"
      echo "  --use-current-branch    Use current branch without prompting"
      echo "  --exclude <path>        Exclude file(s) matching path (can be used multiple times)"
      echo "  --help, -h              Show this help message"
      echo ""
      echo "DEFAULT EXCLUSIONS: scripts/, *.json"
      echo ""
      echo "If no PRD is provided, you will be prompted to use the current branch."
      echo ""
      echo "Example: $0 --verbose PRD-1-infrastructure.json"
      echo "Example: $0 --branch feature/my-feature"
      echo "Example: $0 --use-current-branch"
      echo "Example: $0 --exclude package-lock.json --exclude yarn.lock"
      exit 0
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --branch)
      BRANCH_NAME="$2"
      shift 2
      ;;
    --use-current-branch)
      USE_CURRENT_BRANCH=true
      shift
      ;;
    --exclude)
      EXCLUDE_PATTERNS+=("$2")
      shift 2
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

BASE_BRANCH="master"
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
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  Ralph Diff Gatherer${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "PRD: ${YELLOW}${PRD_PATH}${NC}"
echo -e "Comparing: ${YELLOW}${BASE_BRANCH}${NC} → ${YELLOW}${FEATURE_BRANCH}${NC}"
echo ""

# Default patterns to always exclude (in addition to user-specified ones)
DEFAULT_EXCLUDE_PATTERNS=("scripts/" "*.json")

# Merge default excludes with user-specified excludes
ALL_EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}" "${EXCLUDE_PATTERNS[@]}")

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

    # Build exclude arguments for git diff (includes default + user-specified patterns)
    local exclude_args=""
    for pattern in "${ALL_EXCLUDE_PATTERNS[@]}"; do
        exclude_args+=" ':!${pattern}'"
    done

    # Get the diff (base...feature shows what's in feature that's not in base)
    local diff_output
    if [ -n "$exclude_args" ]; then
        diff_output=$(eval "git diff '${BASE_BRANCH}...${FEATURE_BRANCH}' -- . ${exclude_args}" 2>/dev/null || eval "git diff 'origin/${BASE_BRANCH}...origin/${FEATURE_BRANCH}' -- . ${exclude_args}" 2>/dev/null || echo "")
    else
        diff_output=$(git diff "${BASE_BRANCH}...${FEATURE_BRANCH}" 2>/dev/null || git diff "origin/${BASE_BRANCH}...origin/${FEATURE_BRANCH}" 2>/dev/null || echo "")
    fi

    if [ -z "$diff_output" ]; then
        echo -e "  ${YELLOW}⚠️  No diff found for ${repo_name}${NC}"
        popd > /dev/null
        return
    fi

    # Get stats
    local stats
    if [ -n "$exclude_args" ]; then
        stats=$(eval "git diff --stat '${BASE_BRANCH}...${FEATURE_BRANCH}' -- . ${exclude_args}" 2>/dev/null || eval "git diff --stat 'origin/${BASE_BRANCH}...origin/${FEATURE_BRANCH}' -- . ${exclude_args}" 2>/dev/null || echo "")
    else
        stats=$(git diff --stat "${BASE_BRANCH}...${FEATURE_BRANCH}" 2>/dev/null || git diff --stat "origin/${BASE_BRANCH}...origin/${FEATURE_BRANCH}" 2>/dev/null || echo "")
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

# Add excluded patterns section to output
OUTPUT+="\n## Excluded Patterns\n\n"
OUTPUT+="**Default exclusions:** "
for i in "${!DEFAULT_EXCLUDE_PATTERNS[@]}"; do
    if [ $i -gt 0 ]; then OUTPUT+=", "; fi
    OUTPUT+="\`${DEFAULT_EXCLUDE_PATTERNS[$i]}\`"
done
OUTPUT+="\n"

if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
    OUTPUT+="**User exclusions (--exclude):** "
    for i in "${!EXCLUDE_PATTERNS[@]}"; do
        if [ $i -gt 0 ]; then OUTPUT+=", "; fi
        OUTPUT+="\`${EXCLUDE_PATTERNS[$i]}\`"
    done
    OUTPUT+="\n"
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

# Count tokens accurately using tiktoken
OUTPUT_LEN=${#OUTPUT}

# Setup virtual environment for token counting
VENV_DIR="${SCRIPT_DIR}/.venv"
PYTHON_SCRIPT="${SCRIPT_DIR}/count_tokens.py"

# Function to setup venv and count tokens
count_tokens_accurate() {
    local text="$1"

    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        echo "⚠️  Python 3 not found, using rough estimate"
        echo $((${#text} / 4))
        return
    fi

    # Create virtual environment if it doesn't exist
    if [ ! -d "$VENV_DIR" ]; then
        echo -e "${BLUE}Setting up token counting environment...${NC}"
        python3 -m venv "$VENV_DIR" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo "⚠️  Failed to create virtual environment, using rough estimate"
            echo $((${#text} / 4))
            return
        fi
    fi

    # Install tiktoken if not already installed
    if ! "$VENV_DIR/bin/python" -c "import tiktoken" 2>/dev/null; then
        echo -e "${BLUE}Installing tiktoken...${NC}"
        "$VENV_DIR/bin/pip" install --quiet tiktoken 2>/dev/null
        if [ $? -ne 0 ]; then
            echo "⚠️  Failed to install tiktoken, using rough estimate"
            echo $((${#text} / 4))
            return
        fi
    fi

    # Count tokens using the Python script
    echo -e "$text" | "$VENV_DIR/bin/python" "$PYTHON_SCRIPT" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo $((${#text} / 4))
    fi
}

TOKEN_COUNT=$(count_tokens_accurate "$OUTPUT")
echo -e "📊 Output size: ${OUTPUT_LEN} characters (${TOKEN_COUNT} tokens - cl100k_base/GPT-4)"
