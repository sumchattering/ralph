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
// PRD LOADING
// ============================================================================

function loadPRD(filePath) {
  try {
    const content = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    const stories = content.userStories || [];
    const total = stories.length;
    const completed = stories.filter(s => s.passes && s.typecheck_passes).length;
    const phaseMatch = path.basename(filePath).match(/PRD-(\d+)/);
    const phaseNum = phaseMatch ? parseInt(phaseMatch[1]) : 0;

    return {
      file: filePath,
      phase: phaseNum,
      phaseName: content.phase || '',
      branch: content.branch || '',
      description: content.description || '',
      total,
      completed,
      pending: total - completed,
      isComplete: total > 0 && completed === total
    };
  } catch (err) {
    console.error(`${COLORS.red}Error loading ${filePath}: ${err.message}${COLORS.reset}`);
    return null;
  }
}

// ============================================================================
// DISPLAY
// ============================================================================

function createProgressBar(completed, total, width = 20) {
  if (total === 0) return `${COLORS.gray}${'░'.repeat(width)}${COLORS.reset}`;
  const pct = completed / total;
  const filled = Math.round(pct * width);
  const empty = width - filled;
  return `${COLORS.green}${'█'.repeat(filled)}${COLORS.gray}${'░'.repeat(empty)}${COLORS.reset}`;
}

function showStatus(prds) {
  const totalTasks = prds.reduce((sum, p) => sum + p.total, 0);
  const completedTasks = prds.reduce((sum, p) => sum + p.completed, 0);
  const completedPRDs = prds.filter(p => p.isComplete).length;
  const pendingPRDs = prds.filter(p => !p.isComplete).length;
  const overallPct = totalTasks > 0 ? ((completedTasks / totalTasks) * 100).toFixed(1) : 0;

  console.log(`\n${COLORS.bright}${COLORS.cyan}═══ PRD Status ═══${COLORS.reset}\n`);

  // Per-PRD rows
  for (const prd of prds) {
    const bar = createProgressBar(prd.completed, prd.total);
    const status = prd.isComplete
      ? `${COLORS.green}✓ Complete${COLORS.reset}`
      : `${COLORS.yellow}⧗ Pending ${COLORS.reset}`;
    const counts = `${String(prd.completed).padStart(2)}/${String(prd.total).padEnd(2)}`;
    const label = path.basename(prd.file, '.json').padEnd(40);
    console.log(`  ${label} ${bar}  ${counts}  ${status}`);
  }

  // Summary
  console.log(`\n${COLORS.bright}Overall:${COLORS.reset} ${completedTasks}/${totalTasks} tasks (${overallPct}%)`);
  console.log(`${COLORS.green}Completed PRDs:${COLORS.reset} ${completedPRDs}/${prds.length}`);
  if (pendingPRDs > 0) {
    console.log(`${COLORS.yellow}Pending PRDs:${COLORS.reset}   ${pendingPRDs}`);
  }
  console.log('');
}

function showJSON(prds, mode) {
  if (mode === 'status') {
    const output = {
      prds: prds.map(p => ({
        file: p.file,
        phase: p.phase,
        branch: p.branch,
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
    };
    console.log(JSON.stringify(output, null, 2));
  } else {
    const filtered = mode === 'pending' ? prds.filter(p => !p.isComplete) : prds.filter(p => p.isComplete);
    console.log(JSON.stringify(filtered.map(p => p.file)));
  }
}

// ============================================================================
// HELP
// ============================================================================

function showHelp() {
  console.log(`
${COLORS.bright}${COLORS.cyan}filter-prds.js — PRD completion filter for Ralph${COLORS.reset}

${COLORS.bright}USAGE:${COLORS.reset}
  filter-prds.js [command] [options] <prd-files...>

${COLORS.bright}COMMANDS:${COLORS.reset}
  ${COLORS.green}(default)${COLORS.reset}       Show status summary of all PRDs
  ${COLORS.green}--pending${COLORS.reset}       Output only pending (incomplete) PRD file paths
  ${COLORS.green}--completed${COLORS.reset}     Output only completed PRD file paths

${COLORS.bright}OPTIONS:${COLORS.reset}
  ${COLORS.blue}--json${COLORS.reset}          Output in JSON format
  ${COLORS.blue}--help, -h${COLORS.reset}      Show this help message

${COLORS.bright}EXAMPLES:${COLORS.reset}
  filter-prds.js ./test-spec/naksh/PRD/*.json
  filter-prds.js --pending ./test-spec/naksh/PRD/*.json
  filter-prds.js --completed --json ./PRD-*.json

${COLORS.bright}EXIT CODES:${COLORS.reset}
  0  Results found (or status displayed)
  1  No results for --pending or --completed
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

  const flags = args.filter(a => a.startsWith('--'));
  const files = args.filter(a => !a.startsWith('--'));
  const asJson = flags.includes('--json');
  const mode = flags.includes('--pending') ? 'pending'
    : flags.includes('--completed') ? 'completed'
    : 'status';

  if (files.length === 0) {
    console.error(`${COLORS.red}Error: No PRD files specified${COLORS.reset}`);
    process.exit(1);
  }

  // Load and sort by phase number
  const prds = files
    .map(f => loadPRD(f))
    .filter(p => p !== null)
    .sort((a, b) => a.phase - b.phase);

  if (prds.length === 0) {
    console.error(`${COLORS.red}Error: No valid PRD files found${COLORS.reset}`);
    process.exit(1);
  }

  if (asJson) {
    showJSON(prds, mode);
    if (mode !== 'status') {
      const filtered = mode === 'pending' ? prds.filter(p => !p.isComplete) : prds.filter(p => p.isComplete);
      process.exit(filtered.length > 0 ? 0 : 1);
    }
    return;
  }

  if (mode === 'status') {
    showStatus(prds);
  } else {
    const filtered = mode === 'pending'
      ? prds.filter(p => !p.isComplete)
      : prds.filter(p => p.isComplete);

    // When used as status display (no --quiet), show summary first
    if (mode === 'pending' && prds.some(p => p.isComplete)) {
      const skipped = prds.filter(p => p.isComplete);
      console.error(`${COLORS.dim}Filtered out ${skipped.length} completed PRD(s):${COLORS.reset}`);
      for (const prd of skipped) {
        console.error(`${COLORS.dim}  [DONE] ${prd.file} (${prd.total}/${prd.total} tasks)${COLORS.reset}`);
      }
      console.error('');
    }

    if (filtered.length === 0) {
      if (mode === 'pending') {
        console.error(`${COLORS.green}All ${prds.length} PRD(s) are already completed. Nothing to do.${COLORS.reset}`);
      } else {
        console.error(`${COLORS.yellow}No completed PRDs found.${COLORS.reset}`);
      }
      process.exit(1);
    }

    // Output file paths to stdout (one per line) for script consumption
    for (const prd of filtered) {
      console.log(prd.file);
    }

    process.exit(0);
  }
}

main();
