# Ralph

Ralph is an agentic coding automation system that uses Claude CLI to autonomously work through PRD (Product Requirements Document) tasks in a monorepo.

## Scripts

### ralph.sh

The main automation script. It reads a PRD JSON file and iteratively invokes Claude to:

1. Find the highest-priority incomplete task
2. Navigate to the correct subproject
3. Implement the feature
4. Run typechecks and tests
5. Perform code review via a subagent
6. Commit the changes

**Usage:**
```bash
./ralph.sh <path-to-prd.json> [max-iterations]
```

**Example:**
```bash
./ralph.sh PRD-1-infrastructure.json 50
```

### diff.sh

Gathers diffs between a feature branch (specified in the PRD) and master, then copies them to the clipboard in a formatted markdown document. Useful for code review or sharing changes.

**Usage:**
```bash
./diff.sh <path-to-prd.json>
```

**Example:**
```bash
./diff.sh PRD-2-auth.json
```

### merge.sh

Merges a completed feature branch into the `ralph` integration branch across all submodules and the main repo. Automatically deletes the merged feature branch.

**Usage:**
```bash
./merge.sh <path-to-prd.json>
```

**Example:**
```bash
./merge.sh PRD-2-auth.json
```

## PRD Format

The scripts expect a PRD JSON file with at least the following structure:

```json
{
  "branch": "feature/my-feature",
  "userStories": [
    {
      "id": "TASK-001",
      "description": "Task description",
      "passes": false,
      "typecheck_passes": false
    }
  ]
}
```

## Requirements

- [Claude CLI](https://github.com/anthropics/claude-code) (`claude` command)
- `jq` for JSON parsing
- `git` for version control
- macOS (uses `pbcopy` for clipboard)

## How It Works

1. **ralph.sh** reads the PRD and creates/switches to the feature branch
2. Claude autonomously picks tasks, implements them, runs tests, and commits
3. Progress is logged to `progress.txt`
4. Once all tasks pass, the script exits
5. Use **diff.sh** to review the accumulated changes
6. Use **merge.sh** to merge into the ralph integration branch

## License

MIT License - see [LICENSE](LICENSE) for details.
