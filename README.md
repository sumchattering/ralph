# Ralph

Ralph is an agentic coding automation system that uses Claude CLI to autonomously work through PRD (Product Requirements Document) tasks in a monorepo.

## Philosophy: Spec First, Then Small PRDs

Ralph works best when you follow this workflow:

### 1. Write a Spec First

Before creating PRDs, write a comprehensive specification document that describes your entire feature or product. This spec should cover:

- Overall architecture and design decisions
- Data models and relationships
- API contracts
- UI/UX flows
- Edge cases and error handling

The spec is your source of truth. When Claude works through tasks, it can reference the spec for context and clarification.

### 2. Divide Into Small, Focused PRDs

**Don't try to do 100 tasks in one PRD.** Instead:

- Break your spec into logical phases (e.g., "Phase 1: Database", "Phase 2: Auth", "Phase 3: Core Features")
- Each PRD should have **5-10 tasks maximum**
- Tasks should be completable in a single focused session
- Each PRD should result in a working, testable increment

**Why small PRDs?**

- Claude maintains better context with fewer tasks
- Easier to review and catch issues early
- Faster feedback loops
- Less risk if something goes wrong
- Clearer git history with focused branches

### 3. Sequential Execution

First add this repository as a git submodule to your project.

Then run PRDs in order, merging each completed phase before starting the next:

```bash
# Work through Phase 1
./ralph.sh PRD-1-database.json

# Review changes
./diff.sh PRD-1-database.json

# Merge when satisfied
./merge.sh PRD-1-database.json

# Continue to Phase 2
./ralph.sh PRD-2-auth.json
```

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

Gathers diffs between a feature branch (specified in the PRD) and master, then copies them to the clipboard in a formatted markdown document. Useful for code review or sharing changes. You can paste the whole diff in gemini or another tool to review. This is useful because although we are doing small reviews at the end of each commit we need a large context review also. In the future I want to automate that with codex.

**Usage:**
```bash
./diff.sh <path-to-prd.json>
```

### merge.sh

Merges a completed feature branch into the `ralph` integration branch across all submodules and the main repo. Automatically deletes the merged feature branch. Note. The choice of branch name as ralph is temporary and i will make that configurable at some point.

**Usage:**
```bash
./merge.sh <path-to-prd.json>
```

## PRD Format

See `sample-prd.json` for a complete example. Key fields:

```json
{
  "project": "My App",
  "phase": "1-user-auth",
  "branch": "feature/phase-1-user-auth",
  "description": "Brief description of this phase",
  "total_tasks": 4,
  "generalInstructions": [
    "Project-wide context and guidelines",
    "Reference to spec documents",
    "Testing requirements"
  ],
  "userStories": [
    {
      "id": "AUTH-001",
      "category": "backend",
      "title": "Short task title",
      "priority": 1,
      "complexity": "low|medium|high",
      "dependencies": [],
      "technical_notes": "Implementation details...",
      "acceptance_criteria": ["What must be true when done"],
      "existing_implementation": "Context about current state",
      "passes": false,
      "typecheck_passes": false
    }
  ]
}
```

### Field Descriptions

| Field | Description |
|-------|-------------|
| `branch` | Git branch name for this PRD's work |
| `generalInstructions` | Context given to Claude for every task |
| `userStories` | Array of tasks to complete |
| `priority` | Lower number = higher priority (1 is highest) |
| `dependencies` | Task IDs that must complete first |
| `passes` / `typecheck_passes` | Updated by Ralph as tasks complete |

## Requirements

- [Claude CLI](https://github.com/anthropics/claude-code) (`claude` command)
- `jq` for JSON parsing
- `git` for version control
- macOS (uses `pbcopy` for clipboard)

## Example Workflow

```
project/
├── docs/
│   └── spec.md              # Your comprehensive spec
├── prds/
│   ├── PRD-1-database.json  # 5 tasks: schema setup
│   ├── PRD-2-auth.json      # 6 tasks: authentication
│   ├── PRD-3-api.json       # 8 tasks: core API
│   └── PRD-4-frontend.json  # 7 tasks: UI implementation
└── src/
    └── ...
```

## License

MIT License - see [LICENSE](LICENSE) for details.
