#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

// ============================================================================
// CONSTANTS
// ============================================================================

const COLORS = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  dim: '\x1b[2m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m',
  red: '\x1b[31m',
  gray: '\x1b[90m'
};

// ============================================================================
// CORE DATA LOADING
// ============================================================================

function loadAllPRDs(files) {
  const prds = [];
  const allTasks = [];
  const taskMap = new Map();

  // Sort files by phase number
  const sorted = [...files].sort((a, b) => {
    const numA = parseInt(path.basename(a).match(/PRD-(\d+)/)?.[1] || '0');
    const numB = parseInt(path.basename(b).match(/PRD-(\d+)/)?.[1] || '0');
    return numA - numB;
  });

  for (const filePath of sorted) {
    try {
      const content = JSON.parse(fs.readFileSync(filePath, 'utf8'));
      const basename = path.basename(filePath);
      const phaseNum = parseInt(basename.match(/PRD-(\d+)/)?.[1] || content.phase?.match(/\d+/)?.[0] || '0');

      prds.push({
        file: basename,
        filePath,
        phase: phaseNum,
        ...content
      });

      // Add all tasks with metadata
      if (content.userStories && Array.isArray(content.userStories)) {
        content.userStories.forEach(task => {
          const enrichedTask = {
            ...task,
            phase: phaseNum,
            prdFile: basename,
            prdFilePath: filePath,
            prdPhase: content.phase,
            prdBranch: content.branch,
            completed: task.passes === true && task.typecheck_passes === true
          };
          allTasks.push(enrichedTask);
          taskMap.set(task.id, enrichedTask);
        });
      }
    } catch (err) {
      console.warn(`${COLORS.yellow}Warning: Failed to load ${filePath}: ${err.message}${COLORS.reset}`);
    }
  }

  return { prds, allTasks, taskMap };
}

// ============================================================================
// FILTERING & SEARCH
// ============================================================================

function filterTasks(tasks, filters) {
  let filtered = [...tasks];

  if (filters.completed) {
    filtered = filtered.filter(t => t.completed === true);
  }
  if (filters.pending) {
    filtered = filtered.filter(t => t.completed !== true);
  }
  if (filters.phase !== undefined) {
    filtered = filtered.filter(t => t.phase === filters.phase);
  }
  if (filters.category) {
    filtered = filtered.filter(t => t.category?.toLowerCase() === filters.category.toLowerCase());
  }
  if (filters.priority !== undefined) {
    filtered = filtered.filter(t => t.priority === filters.priority);
  }
  if (filters.complexity) {
    filtered = filtered.filter(t => t.complexity?.toLowerCase() === filters.complexity.toLowerCase());
  }

  return filtered;
}

function searchTasks(tasks, query) {
  const lowerQuery = query.toLowerCase();
  return tasks.filter(task => {
    const searchableText = [
      task.id,
      task.title,
      task.technical_notes,
      task.existing_implementation,
      ...(task.acceptance_criteria || [])
    ].join(' ').toLowerCase();

    return searchableText.includes(lowerQuery);
  });
}

// ============================================================================
// STATISTICS
// ============================================================================

function calculateStats(tasks) {
  const stats = {
    total: tasks.length,
    completed: tasks.filter(t => t.completed).length,
    pending: tasks.filter(t => !t.completed).length,
    byPhase: {},
    byCategory: {},
    byPriority: {},
    byComplexity: {}
  };

  tasks.forEach(task => {
    // By phase
    const phase = `Phase ${task.phase}`;
    if (!stats.byPhase[phase]) stats.byPhase[phase] = { total: 0, completed: 0 };
    stats.byPhase[phase].total++;
    if (task.completed) stats.byPhase[phase].completed++;

    // By category
    const cat = task.category || 'uncategorized';
    if (!stats.byCategory[cat]) stats.byCategory[cat] = { total: 0, completed: 0 };
    stats.byCategory[cat].total++;
    if (task.completed) stats.byCategory[cat].completed++;

    // By priority
    const pri = task.priority || 'none';
    if (!stats.byPriority[pri]) stats.byPriority[pri] = 0;
    stats.byPriority[pri]++;

    // By complexity
    const comp = task.complexity || 'none';
    if (!stats.byComplexity[comp]) stats.byComplexity[comp] = 0;
    stats.byComplexity[comp]++;
  });

  return stats;
}

// ============================================================================
// DEPENDENCY TREE
// ============================================================================

function getDependencyTree(taskId, taskMap) {
  const visited = new Set();
  const tree = { dependencies: [], dependents: [] };

  tree.dependencies = getRecursiveDependencies(taskId, taskMap, visited, 'forward');
  visited.clear();
  tree.dependents = getRecursiveDependencies(taskId, taskMap, visited, 'reverse');

  return tree;
}

function getRecursiveDependencies(taskId, taskMap, visited, direction, depth = 0) {
  if (visited.has(taskId)) return [];
  visited.add(taskId);

  const task = taskMap.get(taskId);
  if (!task) return [];

  const result = [];
  const relatedIds = direction === 'forward'
    ? (task.dependencies || [])
    : Array.from(taskMap.values())
        .filter(t => t.dependencies?.includes(taskId))
        .map(t => t.id);

  for (const relId of relatedIds) {
    const relTask = taskMap.get(relId);
    if (relTask) {
      result.push({
        depth,
        ...relTask,
        children: getRecursiveDependencies(relId, taskMap, visited, direction, depth + 1)
      });
    }
  }

  return result;
}

// ============================================================================
// FORMATTING - TABLE
// ============================================================================

function formatTable(tasks) {
  if (tasks.length === 0) {
    console.log(`${COLORS.gray}No tasks found${COLORS.reset}`);
    return;
  }

  // Header
  console.log(`\n${COLORS.bright}ID          Phase  Category    Pri  Complexity  Status      Title${COLORS.reset}`);
  console.log('\u2500'.repeat(100));

  tasks.forEach(task => {
    const status = task.completed
      ? `${COLORS.green}\u2713 Complete${COLORS.reset}`
      : `${COLORS.yellow}\u29D7 Pending ${COLORS.reset}`;

    const id = task.id.padEnd(10);
    const phase = String(task.phase).padEnd(5);
    const category = (task.category || '-').padEnd(11);
    const priority = String(task.priority || '-').padEnd(3);
    const complexity = (task.complexity || '-').padEnd(11);
    const title = task.title.substring(0, 50);

    console.log(`${id}  ${phase}  ${category}  ${priority}  ${complexity}  ${status}  ${title}`);
  });

  console.log('');
}

// ============================================================================
// FORMATTING - JSON
// ============================================================================

function formatJSON(data) {
  console.log(JSON.stringify(data, null, 2));
}

// ============================================================================
// COMMANDS
// ============================================================================

function commandStatus(allTasks, asJson = false) {
  const stats = calculateStats(allTasks);
  const completionPct = stats.total > 0
    ? ((stats.completed / stats.total) * 100).toFixed(1)
    : 0;

  if (asJson) {
    formatJSON(stats);
    return;
  }

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 PRD Status Summary \u2550\u2550\u2550${COLORS.reset}\n`);
  console.log(`${COLORS.bright}Total Tasks:${COLORS.reset} ${stats.total}`);
  console.log(`${COLORS.green}Completed:${COLORS.reset}   ${stats.completed} (${completionPct}%)`);
  console.log(`${COLORS.yellow}Pending:${COLORS.reset}     ${stats.pending}`);

  // By Phase
  console.log(`\n${COLORS.bright}By Phase:${COLORS.reset}`);
  Object.keys(stats.byPhase).sort().forEach(phase => {
    const { total, completed } = stats.byPhase[phase];
    const pct = ((completed / total) * 100).toFixed(0);
    const bar = createProgressBar(completed, total, 20);
    console.log(`  ${phase}: ${bar} ${completed}/${total} (${pct}%)`);
  });

  // By Category
  console.log(`\n${COLORS.bright}By Category:${COLORS.reset}`);
  Object.keys(stats.byCategory).sort().forEach(cat => {
    const { total, completed } = stats.byCategory[cat];
    console.log(`  ${cat.padEnd(12)}: ${completed}/${total}`);
  });

  // By Priority
  console.log(`\n${COLORS.bright}By Priority:${COLORS.reset}`);
  Object.keys(stats.byPriority).sort().forEach(pri => {
    console.log(`  Priority ${pri}: ${stats.byPriority[pri]}`);
  });

  // By Complexity
  console.log(`\n${COLORS.bright}By Complexity:${COLORS.reset}`);
  ['low', 'medium', 'high'].forEach(comp => {
    if (stats.byComplexity[comp]) {
      console.log(`  ${comp.padEnd(8)}: ${stats.byComplexity[comp]}`);
    }
  });

  console.log('');
}

function commandList(allTasks, filters, asJson = false) {
  let tasks = filterTasks(allTasks, filters);

  if (asJson) {
    formatJSON({
      total: tasks.length,
      filters,
      tasks
    });
  } else {
    formatTable(tasks);
  }
}

function commandShow(taskId, taskMap, asJson = false) {
  // Support partial ID matching
  let task = taskMap.get(taskId);

  if (!task) {
    const matches = Array.from(taskMap.values()).filter(t =>
      t.id.toLowerCase().includes(taskId.toLowerCase())
    );

    if (matches.length === 0) {
      console.error(`${COLORS.red}Task not found: ${taskId}${COLORS.reset}`);
      process.exit(1);
    } else if (matches.length === 1) {
      task = matches[0];
    } else {
      console.error(`${COLORS.red}Multiple tasks match '${taskId}':${COLORS.reset}`);
      matches.forEach(t => console.log(`  ${t.id}: ${t.title}`));
      process.exit(1);
    }
  }

  if (asJson) {
    formatJSON(task);
    return;
  }

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 ${task.id} \u2550\u2550\u2550${COLORS.reset}\n`);
  console.log(`${COLORS.bright}Title:${COLORS.reset}       ${task.title}`);
  console.log(`${COLORS.bright}Phase:${COLORS.reset}       ${task.phase} (${task.prdPhase})`);
  console.log(`${COLORS.bright}Category:${COLORS.reset}    ${task.category || 'N/A'}`);
  console.log(`${COLORS.bright}Priority:${COLORS.reset}    ${task.priority || 'N/A'}`);
  console.log(`${COLORS.bright}Complexity:${COLORS.reset}  ${task.complexity || 'N/A'}`);
  console.log(`${COLORS.bright}Status:${COLORS.reset}      ${task.completed ? COLORS.green + '\u2713 Complete' : COLORS.yellow + '\u29D7 Pending'}${COLORS.reset}`);
  console.log(`${COLORS.bright}Branch:${COLORS.reset}      ${task.prdBranch || 'N/A'}`);

  if (task.dependencies && task.dependencies.length > 0) {
    console.log(`\n${COLORS.bright}Dependencies:${COLORS.reset}`);
    task.dependencies.forEach(depId => {
      const dep = taskMap.get(depId);
      console.log(`  \u2022 ${depId}${dep ? ': ' + dep.title : ''}`);
    });
  }

  if (task.technical_notes) {
    console.log(`\n${COLORS.bright}Technical Notes:${COLORS.reset}`);
    console.log(wrapText(task.technical_notes, 80, '  '));
  }

  if (task.acceptance_criteria && task.acceptance_criteria.length > 0) {
    console.log(`\n${COLORS.bright}Acceptance Criteria:${COLORS.reset}`);
    task.acceptance_criteria.forEach(criterion => {
      console.log(`  \u2022 ${criterion}`);
    });
  }

  if (task.existing_implementation) {
    console.log(`\n${COLORS.bright}Existing Implementation:${COLORS.reset}`);
    console.log(wrapText(task.existing_implementation, 80, '  '));
  }

  console.log('');
}

function commandSearch(allTasks, query, asJson = false) {
  const results = searchTasks(allTasks, query);

  if (asJson) {
    formatJSON({
      query,
      matches: results.length,
      tasks: results
    });
  } else {
    console.log(`\n${COLORS.bright}Search results for "${query}": ${results.length} matches${COLORS.reset}\n`);
    formatTable(results);
  }
}

function commandDeps(taskId, taskMap, asJson = false) {
  let task = taskMap.get(taskId);

  if (!task) {
    const matches = Array.from(taskMap.values()).filter(t =>
      t.id.toLowerCase().includes(taskId.toLowerCase())
    );

    if (matches.length === 1) {
      task = matches[0];
    } else {
      console.error(`${COLORS.red}Task not found: ${taskId}${COLORS.reset}`);
      process.exit(1);
    }
  }

  const tree = getDependencyTree(task.id, taskMap);

  if (asJson) {
    formatJSON({ task: task.id, ...tree });
    return;
  }

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 Dependency Tree: ${task.id} \u2550\u2550\u2550${COLORS.reset}\n`);

  if (tree.dependencies.length > 0) {
    console.log(`${COLORS.bright}Dependencies (what ${task.id} depends on):${COLORS.reset}`);
    printDepTree(tree.dependencies);
  } else {
    console.log(`${COLORS.gray}No dependencies${COLORS.reset}`);
  }

  if (tree.dependents.length > 0) {
    console.log(`\n${COLORS.bright}Dependents (what depends on ${task.id}):${COLORS.reset}`);
    printDepTree(tree.dependents);
  } else {
    console.log(`${COLORS.gray}No dependents${COLORS.reset}`);
  }

  console.log('');
}

// ============================================================================
// UTILITIES
// ============================================================================

function createProgressBar(completed, total, width = 20) {
  if (total === 0) return `${COLORS.gray}${'\u2591'.repeat(width)}${COLORS.reset}`;
  const pct = completed / total;
  const filled = Math.round(pct * width);
  const empty = width - filled;
  return `${COLORS.green}${'\u2588'.repeat(filled)}${COLORS.gray}${'\u2591'.repeat(empty)}${COLORS.reset}`;
}

function wrapText(text, width, indent = '') {
  const words = text.split(' ');
  const lines = [];
  let currentLine = '';

  words.forEach(word => {
    if ((currentLine + word).length > width - indent.length) {
      lines.push(indent + currentLine.trim());
      currentLine = word + ' ';
    } else {
      currentLine += word + ' ';
    }
  });

  if (currentLine) {
    lines.push(indent + currentLine.trim());
  }

  return lines.join('\n');
}

function printDepTree(deps, depth = 0) {
  deps.forEach((dep, idx) => {
    const isLast = idx === deps.length - 1;
    const prefix = '  '.repeat(depth) + (isLast ? '\u2514\u2500 ' : '\u251C\u2500 ');
    const status = dep.completed ? COLORS.green + '\u2713' : COLORS.yellow + '\u29D7';
    console.log(`${prefix}${status} ${dep.id}${COLORS.reset}: ${dep.title}`);

    if (dep.children && dep.children.length > 0) {
      printDepTree(dep.children, depth + 1);
    }
  });
}

function showHelp() {
  console.log(`
${COLORS.bright}${COLORS.cyan}prd-query.js \u2014 PRD Task Query Tool${COLORS.reset}

${COLORS.bright}USAGE:${COLORS.reset}
  prd-query.js [command] [options] -- <prd-files...>

  Files are passed after -- separator.

${COLORS.bright}COMMANDS:${COLORS.reset}
  ${COLORS.green}--status${COLORS.reset}              Show summary statistics across all PRDs (default)
  ${COLORS.green}--list${COLORS.reset}                List all tasks (supports filters)
  ${COLORS.green}--show${COLORS.reset} <task-id>      Show detailed information for a task
  ${COLORS.green}--search${COLORS.reset} <query>      Search tasks by keyword
  ${COLORS.green}--deps${COLORS.reset} <task-id>      Show dependency tree for a task

${COLORS.bright}FILTERS:${COLORS.reset} (use with --list)
  ${COLORS.blue}--completed${COLORS.reset}            Only show completed tasks
  ${COLORS.blue}--pending${COLORS.reset}              Only show pending tasks
  ${COLORS.blue}--phase${COLORS.reset} <number>       Filter by phase (1-6)
  ${COLORS.blue}--category${COLORS.reset} <name>      Filter by category (mobile, backend, database)
  ${COLORS.blue}--priority${COLORS.reset} <number>    Filter by priority level
  ${COLORS.blue}--complexity${COLORS.reset} <level>   Filter by complexity (low, medium, high)

${COLORS.bright}OPTIONS:${COLORS.reset}
  ${COLORS.blue}--json${COLORS.reset}                 Output in JSON format
  ${COLORS.blue}--help${COLORS.reset}                 Show this help message

${COLORS.bright}NOTE:${COLORS.reset} This script is typically called via status.sh which handles
file resolution. Direct usage requires passing files after --.
`);
}

// ============================================================================
// MAIN
// ============================================================================

function main() {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h')) {
    showHelp();
    process.exit(0);
  }

  // Split args at -- separator: flags before, files after
  const separatorIdx = args.indexOf('--');
  let flags, files;
  if (separatorIdx >= 0) {
    flags = args.slice(0, separatorIdx);
    files = args.slice(separatorIdx + 1);
  } else {
    // No separator: treat non-flag args as files
    flags = args.filter(a => a.startsWith('--'));
    files = args.filter(a => !a.startsWith('-'));
    // Also grab values for flags that take arguments
    const valueFlags = ['--show', '--search', '--deps', '--phase', '--category', '--priority', '--complexity'];
    for (const vf of valueFlags) {
      const idx = args.indexOf(vf);
      if (idx >= 0 && idx + 1 < args.length) {
        const val = args[idx + 1];
        // Remove the value from files array if it ended up there
        const fileIdx = files.indexOf(val);
        if (fileIdx >= 0) files.splice(fileIdx, 1);
      }
    }
  }

  if (files.length === 0) {
    console.error(`${COLORS.red}Error: No PRD files specified${COLORS.reset}`);
    console.error(`${COLORS.dim}Usage: prd-query.js [command] [options] -- <files...>${COLORS.reset}`);
    process.exit(1);
  }

  const { allTasks, taskMap } = loadAllPRDs(files);

  if (allTasks.length === 0) {
    console.error(`${COLORS.red}Error: No tasks found in provided PRD files${COLORS.reset}`);
    process.exit(1);
  }

  const asJson = args.includes('--json');

  // Determine command
  if (args.includes('--list')) {
    const filters = {
      completed: args.includes('--completed'),
      pending: args.includes('--pending'),
      phase: args.includes('--phase') ? parseInt(args[args.indexOf('--phase') + 1]) : undefined,
      category: args.includes('--category') ? args[args.indexOf('--category') + 1] : undefined,
      priority: args.includes('--priority') ? parseInt(args[args.indexOf('--priority') + 1]) : undefined,
      complexity: args.includes('--complexity') ? args[args.indexOf('--complexity') + 1] : undefined,
    };
    commandList(allTasks, filters, asJson);
  }
  else if (args.includes('--show')) {
    const taskId = args[args.indexOf('--show') + 1];
    if (!taskId || taskId.startsWith('--')) {
      console.error(`${COLORS.red}Error: --show requires a task ID${COLORS.reset}`);
      process.exit(1);
    }
    commandShow(taskId, taskMap, asJson);
  }
  else if (args.includes('--search')) {
    const query = args[args.indexOf('--search') + 1];
    if (!query || query.startsWith('--')) {
      console.error(`${COLORS.red}Error: --search requires a query${COLORS.reset}`);
      process.exit(1);
    }
    commandSearch(allTasks, query, asJson);
  }
  else if (args.includes('--deps')) {
    const taskId = args[args.indexOf('--deps') + 1];
    if (!taskId || taskId.startsWith('--')) {
      console.error(`${COLORS.red}Error: --deps requires a task ID${COLORS.reset}`);
      process.exit(1);
    }
    commandDeps(taskId, taskMap, asJson);
  }
  else {
    // Default: --status
    commandStatus(allTasks, asJson);
  }
}

main();
