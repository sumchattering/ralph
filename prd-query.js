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

function loadPRDs(files) {
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
      const stories = content.userStories || [];
      const completed = stories.filter(s => s.passes === true && s.typecheck_passes === true).length;

      const prd = {
        file: basename,
        filePath,
        phase: phaseNum,
        phaseName: content.phase || '',
        branch: content.branch || '',
        description: content.description || '',
        total: stories.length,
        completed,
        pending: stories.length - completed,
        isComplete: stories.length > 0 && completed === stories.length,
        content
      };
      prds.push(prd);

      // Add all tasks with metadata
      stories.forEach(task => {
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
    } catch (err) {
      console.error(`${COLORS.red}Error loading ${filePath}: ${err.message}${COLORS.reset}`);
    }
  }

  return { prds, allTasks, taskMap };
}

// ============================================================================
// FILTERING & SEARCH
// ============================================================================

function filterTasks(tasks, filters) {
  let filtered = [...tasks];

  if (filters.completed) filtered = filtered.filter(t => t.completed === true);
  if (filters.pending) filtered = filtered.filter(t => t.completed !== true);
  if (filters.phase !== undefined) filtered = filtered.filter(t => t.phase === filters.phase);
  if (filters.category) filtered = filtered.filter(t => t.category?.toLowerCase() === filters.category.toLowerCase());
  if (filters.priority !== undefined) filtered = filtered.filter(t => t.priority === filters.priority);
  if (filters.complexity) filtered = filtered.filter(t => t.complexity?.toLowerCase() === filters.complexity.toLowerCase());

  return filtered;
}

function searchTasks(tasks, query) {
  const lowerQuery = query.toLowerCase();
  return tasks.filter(task => {
    return [
      task.id, task.title, task.technical_notes, task.existing_implementation,
      ...(task.acceptance_criteria || [])
    ].join(' ').toLowerCase().includes(lowerQuery);
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
    byPhase: {}, byCategory: {}, byPriority: {}, byComplexity: {}
  };

  tasks.forEach(task => {
    const phase = `Phase ${task.phase}`;
    if (!stats.byPhase[phase]) stats.byPhase[phase] = { total: 0, completed: 0 };
    stats.byPhase[phase].total++;
    if (task.completed) stats.byPhase[phase].completed++;

    const cat = task.category || 'uncategorized';
    if (!stats.byCategory[cat]) stats.byCategory[cat] = { total: 0, completed: 0 };
    stats.byCategory[cat].total++;
    if (task.completed) stats.byCategory[cat].completed++;

    const pri = task.priority || 'none';
    if (!stats.byPriority[pri]) stats.byPriority[pri] = 0;
    stats.byPriority[pri]++;

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
  const deps = getRecursiveDeps(taskId, taskMap, new Set(), 'forward');
  const dependents = getRecursiveDeps(taskId, taskMap, new Set(), 'reverse');
  return { dependencies: deps, dependents };
}

function getRecursiveDeps(taskId, taskMap, visited, direction, depth = 0) {
  if (visited.has(taskId)) return [];
  visited.add(taskId);

  const task = taskMap.get(taskId);
  if (!task) return [];

  const relatedIds = direction === 'forward'
    ? (task.dependencies || [])
    : Array.from(taskMap.values()).filter(t => t.dependencies?.includes(taskId)).map(t => t.id);

  return relatedIds.map(relId => {
    const relTask = taskMap.get(relId);
    return relTask ? { depth, ...relTask, children: getRecursiveDeps(relId, taskMap, visited, direction, depth + 1) } : null;
  }).filter(Boolean);
}

// ============================================================================
// UTILITIES
// ============================================================================

function createProgressBar(completed, total, width = 20) {
  if (total === 0) return `${COLORS.gray}${'\u2591'.repeat(width)}${COLORS.reset}`;
  const filled = Math.round((completed / total) * width);
  return `${COLORS.green}${'\u2588'.repeat(filled)}${COLORS.gray}${'\u2591'.repeat(width - filled)}${COLORS.reset}`;
}

function wrapText(text, width, indent = '') {
  const words = text.split(' ');
  const lines = [];
  let cur = '';
  words.forEach(word => {
    if ((cur + word).length > width - indent.length) { lines.push(indent + cur.trim()); cur = word + ' '; }
    else cur += word + ' ';
  });
  if (cur) lines.push(indent + cur.trim());
  return lines.join('\n');
}

function printDepTree(deps, depth = 0) {
  deps.forEach((dep, idx) => {
    const prefix = '  '.repeat(depth) + (idx === deps.length - 1 ? '\u2514\u2500 ' : '\u251C\u2500 ');
    const status = dep.completed ? COLORS.green + '\u2713' : COLORS.yellow + '\u29D7';
    console.log(`${prefix}${status} ${dep.id}${COLORS.reset}: ${dep.title}`);
    if (dep.children?.length > 0) printDepTree(dep.children, depth + 1);
  });
}

// ============================================================================
// COMMANDS — PRD-level (overview, pending/completed file paths)
// ============================================================================

function commandOverview(prds, asJson = false) {
  if (asJson) {
    console.log(JSON.stringify({
      prds: prds.map(p => ({
        file: p.filePath, phase: p.phase, branch: p.branch,
        tasks: { total: p.total, completed: p.completed, pending: p.pending },
        isComplete: p.isComplete
      })),
      summary: {
        totalPRDs: prds.length,
        completedPRDs: prds.filter(p => p.isComplete).length,
        pendingPRDs: prds.filter(p => !p.isComplete).length,
        totalTasks: prds.reduce((s, p) => s + p.total, 0),
        completedTasks: prds.reduce((s, p) => s + p.completed, 0)
      }
    }, null, 2));
    return;
  }

  const totalTasks = prds.reduce((s, p) => s + p.total, 0);
  const completedTasks = prds.reduce((s, p) => s + p.completed, 0);
  const overallPct = totalTasks > 0 ? ((completedTasks / totalTasks) * 100).toFixed(1) : 0;

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 PRD Status \u2550\u2550\u2550${COLORS.reset}\n`);
  for (const prd of prds) {
    const bar = createProgressBar(prd.completed, prd.total);
    const status = prd.isComplete ? `${COLORS.green}\u2713 Complete${COLORS.reset}` : `${COLORS.yellow}\u29D7 Pending ${COLORS.reset}`;
    const counts = `${String(prd.completed).padStart(2)}/${String(prd.total).padEnd(2)}`;
    console.log(`  ${path.basename(prd.filePath, '.json').padEnd(40)} ${bar}  ${counts}  ${status}`);
  }
  console.log(`\n${COLORS.bright}Overall:${COLORS.reset} ${completedTasks}/${totalTasks} tasks (${overallPct}%)`);
  console.log(`${COLORS.green}Completed PRDs:${COLORS.reset} ${prds.filter(p => p.isComplete).length}/${prds.length}`);
  if (prds.some(p => !p.isComplete)) console.log(`${COLORS.yellow}Pending PRDs:${COLORS.reset}   ${prds.filter(p => !p.isComplete).length}`);
  console.log('');
}

function commandPending(prds, asJson = false) {
  const completed = prds.filter(p => p.isComplete);
  const pending = prds.filter(p => !p.isComplete);

  if (asJson) {
    console.log(JSON.stringify(pending.map(p => p.filePath)));
    process.exit(pending.length > 0 ? 0 : 1);
  }

  if (completed.length > 0) {
    console.error(`${COLORS.dim}Filtered out ${completed.length} completed PRD(s):${COLORS.reset}`);
    completed.forEach(p => console.error(`${COLORS.dim}  [DONE] ${p.filePath} (${p.total}/${p.total} tasks)${COLORS.reset}`));
    console.error('');
  }

  if (pending.length === 0) {
    console.error(`${COLORS.green}All ${prds.length} PRD(s) are already completed. Nothing to do.${COLORS.reset}`);
    process.exit(1);
  }

  pending.forEach(p => console.log(p.filePath));
  process.exit(0);
}

function commandCompleted(prds, asJson = false) {
  const completed = prds.filter(p => p.isComplete);

  if (asJson) {
    console.log(JSON.stringify(completed.map(p => p.filePath)));
    process.exit(completed.length > 0 ? 0 : 1);
  }

  if (completed.length === 0) {
    console.error(`${COLORS.yellow}No completed PRDs found.${COLORS.reset}`);
    process.exit(1);
  }

  completed.forEach(p => console.log(p.filePath));
  process.exit(0);
}

// ============================================================================
// COMMANDS — Task-level (status, list, show, search, deps)
// ============================================================================

function commandStatus(allTasks, asJson = false) {
  const stats = calculateStats(allTasks);
  const pct = stats.total > 0 ? ((stats.completed / stats.total) * 100).toFixed(1) : 0;

  if (asJson) { console.log(JSON.stringify(stats, null, 2)); return; }

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 PRD Status Summary \u2550\u2550\u2550${COLORS.reset}\n`);
  console.log(`${COLORS.bright}Total Tasks:${COLORS.reset} ${stats.total}`);
  console.log(`${COLORS.green}Completed:${COLORS.reset}   ${stats.completed} (${pct}%)`);
  console.log(`${COLORS.yellow}Pending:${COLORS.reset}     ${stats.pending}`);

  console.log(`\n${COLORS.bright}By Phase:${COLORS.reset}`);
  Object.keys(stats.byPhase).sort().forEach(phase => {
    const { total, completed } = stats.byPhase[phase];
    console.log(`  ${phase}: ${createProgressBar(completed, total, 20)} ${completed}/${total} (${((completed / total) * 100).toFixed(0)}%)`);
  });

  console.log(`\n${COLORS.bright}By Category:${COLORS.reset}`);
  Object.keys(stats.byCategory).sort().forEach(cat => {
    const { total, completed } = stats.byCategory[cat];
    console.log(`  ${cat.padEnd(12)}: ${completed}/${total}`);
  });

  console.log(`\n${COLORS.bright}By Priority:${COLORS.reset}`);
  Object.keys(stats.byPriority).sort().forEach(pri => console.log(`  Priority ${pri}: ${stats.byPriority[pri]}`));

  console.log(`\n${COLORS.bright}By Complexity:${COLORS.reset}`);
  ['low', 'medium', 'high'].forEach(comp => {
    if (stats.byComplexity[comp]) console.log(`  ${comp.padEnd(8)}: ${stats.byComplexity[comp]}`);
  });
  console.log('');
}

function commandList(allTasks, filters, asJson = false) {
  const tasks = filterTasks(allTasks, filters);
  if (asJson) { console.log(JSON.stringify({ total: tasks.length, filters, tasks }, null, 2)); return; }

  if (tasks.length === 0) { console.log(`${COLORS.gray}No tasks found${COLORS.reset}`); return; }

  console.log(`\n${COLORS.bright}ID          Phase  Category    Pri  Complexity  Status      Title${COLORS.reset}`);
  console.log('\u2500'.repeat(100));
  tasks.forEach(task => {
    const status = task.completed ? `${COLORS.green}\u2713 Complete${COLORS.reset}` : `${COLORS.yellow}\u29D7 Pending ${COLORS.reset}`;
    console.log(`${task.id.padEnd(10)}  ${String(task.phase).padEnd(5)}  ${(task.category || '-').padEnd(11)}  ${String(task.priority || '-').padEnd(3)}  ${(task.complexity || '-').padEnd(11)}  ${status}  ${task.title.substring(0, 50)}`);
  });
  console.log('');
}

function commandShow(taskId, taskMap, asJson = false) {
  let task = taskMap.get(taskId);
  if (!task) {
    const matches = Array.from(taskMap.values()).filter(t => t.id.toLowerCase().includes(taskId.toLowerCase()));
    if (matches.length === 0) { console.error(`${COLORS.red}Task not found: ${taskId}${COLORS.reset}`); process.exit(1); }
    if (matches.length > 1) { console.error(`${COLORS.red}Multiple tasks match '${taskId}':${COLORS.reset}`); matches.forEach(t => console.log(`  ${t.id}: ${t.title}`)); process.exit(1); }
    task = matches[0];
  }

  if (asJson) { console.log(JSON.stringify(task, null, 2)); return; }

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 ${task.id} \u2550\u2550\u2550${COLORS.reset}\n`);
  console.log(`${COLORS.bright}Title:${COLORS.reset}       ${task.title}`);
  console.log(`${COLORS.bright}Phase:${COLORS.reset}       ${task.phase} (${task.prdPhase})`);
  console.log(`${COLORS.bright}Category:${COLORS.reset}    ${task.category || 'N/A'}`);
  console.log(`${COLORS.bright}Priority:${COLORS.reset}    ${task.priority || 'N/A'}`);
  console.log(`${COLORS.bright}Complexity:${COLORS.reset}  ${task.complexity || 'N/A'}`);
  console.log(`${COLORS.bright}Status:${COLORS.reset}      ${task.completed ? COLORS.green + '\u2713 Complete' : COLORS.yellow + '\u29D7 Pending'}${COLORS.reset}`);
  console.log(`${COLORS.bright}Branch:${COLORS.reset}      ${task.prdBranch || 'N/A'}`);

  if (task.dependencies?.length > 0) {
    console.log(`\n${COLORS.bright}Dependencies:${COLORS.reset}`);
    task.dependencies.forEach(depId => { const dep = taskMap.get(depId); console.log(`  \u2022 ${depId}${dep ? ': ' + dep.title : ''}`); });
  }
  if (task.technical_notes) { console.log(`\n${COLORS.bright}Technical Notes:${COLORS.reset}`); console.log(wrapText(task.technical_notes, 80, '  ')); }
  if (task.acceptance_criteria?.length > 0) { console.log(`\n${COLORS.bright}Acceptance Criteria:${COLORS.reset}`); task.acceptance_criteria.forEach(c => console.log(`  \u2022 ${c}`)); }
  if (task.existing_implementation) { console.log(`\n${COLORS.bright}Existing Implementation:${COLORS.reset}`); console.log(wrapText(task.existing_implementation, 80, '  ')); }
  console.log('');
}

function commandSearch(allTasks, query, asJson = false) {
  const results = searchTasks(allTasks, query);
  if (asJson) { console.log(JSON.stringify({ query, matches: results.length, tasks: results }, null, 2)); return; }
  console.log(`\n${COLORS.bright}Search results for "${query}": ${results.length} matches${COLORS.reset}\n`);
  commandList(results, {}, false);
}

function commandDeps(taskId, taskMap, asJson = false) {
  let task = taskMap.get(taskId);
  if (!task) {
    const matches = Array.from(taskMap.values()).filter(t => t.id.toLowerCase().includes(taskId.toLowerCase()));
    if (matches.length === 1) task = matches[0];
    else { console.error(`${COLORS.red}Task not found: ${taskId}${COLORS.reset}`); process.exit(1); }
  }

  const tree = getDependencyTree(task.id, taskMap);
  if (asJson) { console.log(JSON.stringify({ task: task.id, ...tree }, null, 2)); return; }

  console.log(`\n${COLORS.bright}${COLORS.cyan}\u2550\u2550\u2550 Dependency Tree: ${task.id} \u2550\u2550\u2550${COLORS.reset}\n`);
  if (tree.dependencies.length > 0) { console.log(`${COLORS.bright}Dependencies (what ${task.id} depends on):${COLORS.reset}`); printDepTree(tree.dependencies); }
  else console.log(`${COLORS.gray}No dependencies${COLORS.reset}`);
  if (tree.dependents.length > 0) { console.log(`\n${COLORS.bright}Dependents (what depends on ${task.id}):${COLORS.reset}`); printDepTree(tree.dependents); }
  else console.log(`${COLORS.gray}No dependents${COLORS.reset}`);
  console.log('');
}

// ============================================================================
// HELP
// ============================================================================

function showHelp() {
  console.log(`
${COLORS.bright}${COLORS.cyan}prd-query.js \u2014 Unified PRD Status & Query Tool${COLORS.reset}

${COLORS.bright}USAGE:${COLORS.reset}
  prd-query.js [command] [options] -- <prd-files...>

${COLORS.bright}COMMANDS (PRD-level):${COLORS.reset}
  ${COLORS.green}(default)${COLORS.reset}             Show PRD-level overview with progress bars
  ${COLORS.green}--pending${COLORS.reset}             Output file paths of incomplete PRDs (for scripting)
  ${COLORS.green}--completed${COLORS.reset}           Output file paths of completed PRDs (for scripting)

${COLORS.bright}COMMANDS (Task-level):${COLORS.reset}
  ${COLORS.green}--status${COLORS.reset}              Show task-level summary statistics
  ${COLORS.green}--list${COLORS.reset}                List all tasks (supports filters)
  ${COLORS.green}--show${COLORS.reset} <task-id>      Show detailed information for a task
  ${COLORS.green}--search${COLORS.reset} <query>      Search tasks by keyword
  ${COLORS.green}--deps${COLORS.reset} <task-id>      Show dependency tree for a task

${COLORS.bright}FILTERS:${COLORS.reset} (use with --list)
  ${COLORS.blue}--phase${COLORS.reset} <number>       Filter by phase
  ${COLORS.blue}--category${COLORS.reset} <name>      Filter by category (mobile, backend, database)
  ${COLORS.blue}--priority${COLORS.reset} <number>    Filter by priority level
  ${COLORS.blue}--complexity${COLORS.reset} <level>   Filter by complexity (low, medium, high)
  ${COLORS.blue}--task-completed${COLORS.reset}       Only completed tasks (with --list)
  ${COLORS.blue}--task-pending${COLORS.reset}         Only pending tasks (with --list)

${COLORS.bright}OPTIONS:${COLORS.reset}
  ${COLORS.blue}--json${COLORS.reset}                 Output in JSON format
  ${COLORS.blue}--help, -h${COLORS.reset}             Show this help message

${COLORS.bright}NOTE:${COLORS.reset} Typically called via status.sh which handles file resolution.
`);
}

// ============================================================================
// MAIN
// ============================================================================

function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
    showHelp();
    process.exit(0);
  }

  // Split args at -- separator: flags before, files after
  const separatorIdx = args.indexOf('--');
  let files;
  if (separatorIdx >= 0) {
    files = args.slice(separatorIdx + 1);
  } else {
    // No separator: non-flag args are files, but skip values of value-flags
    const valueFlags = ['--show', '--search', '--deps', '--phase', '--category', '--priority', '--complexity'];
    const skipNext = new Set();
    for (const vf of valueFlags) {
      const idx = args.indexOf(vf);
      if (idx >= 0 && idx + 1 < args.length) skipNext.add(idx + 1);
    }
    files = args.filter((a, i) => !a.startsWith('-') && !skipNext.has(i));
  }

  if (files.length === 0) {
    console.error(`${COLORS.red}Error: No PRD files specified${COLORS.reset}`);
    process.exit(1);
  }

  const { prds, allTasks, taskMap } = loadPRDs(files);
  const asJson = args.includes('--json');

  const hasList = args.includes('--list');

  // PRD-level commands (only when --list is NOT present)
  if (args.includes('--pending') && !hasList) return commandPending(prds, asJson);
  if (args.includes('--completed') && !hasList) return commandCompleted(prds, asJson);

  // Task-level commands
  if (args.includes('--status')) return commandStatus(allTasks, asJson);
  if (hasList) {
    return commandList(allTasks, {
      completed: args.includes('--completed'),
      pending: args.includes('--pending'),
      phase: args.includes('--phase') ? parseInt(args[args.indexOf('--phase') + 1]) : undefined,
      category: args.includes('--category') ? args[args.indexOf('--category') + 1] : undefined,
      priority: args.includes('--priority') ? parseInt(args[args.indexOf('--priority') + 1]) : undefined,
      complexity: args.includes('--complexity') ? args[args.indexOf('--complexity') + 1] : undefined,
    }, asJson);
  }
  if (args.includes('--show')) {
    const id = args[args.indexOf('--show') + 1];
    if (!id || id.startsWith('--')) { console.error(`${COLORS.red}Error: --show requires a task ID${COLORS.reset}`); process.exit(1); }
    return commandShow(id, taskMap, asJson);
  }
  if (args.includes('--search')) {
    const q = args[args.indexOf('--search') + 1];
    if (!q || q.startsWith('--')) { console.error(`${COLORS.red}Error: --search requires a query${COLORS.reset}`); process.exit(1); }
    return commandSearch(allTasks, q, asJson);
  }
  if (args.includes('--deps')) {
    const id = args[args.indexOf('--deps') + 1];
    if (!id || id.startsWith('--')) { console.error(`${COLORS.red}Error: --deps requires a task ID${COLORS.reset}`); process.exit(1); }
    return commandDeps(id, taskMap, asJson);
  }

  // Default: PRD-level overview
  commandOverview(prds, asJson);
}

main();
