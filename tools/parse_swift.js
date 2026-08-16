#!/usr/bin/env node
//
// A real Swift parser, for a session that has no Swift compiler.
//
// Why this exists. On 16 August this project shipped two compile errors in one evening, both found
// by grep after the fact and neither by reading: an unannotated heterogeneous dictionary literal,
// and eleven empty collection literals in `Any` position. The only gate on this side was brace
// counting, which cannot see either. Every real check meant Alex building on his Mac and reporting
// back, and that loop cost most of a day.
//
// `download.swift.org`, `github.com` releases and `objects.githubusercontent.com` are all refused by
// the session proxy, so a toolchain is genuinely unavailable. But `registry.npmjs.org` bypasses the
// proxy entirely, and tree-sitter's Swift grammar is on it. That gives a true syntax parse: not type
// checking, but every unbalanced construct, every malformed expression, every missing token.
//
//   npm install tree-sitter tree-sitter-swift
//   node tools/parse_swift.js
//
// Exits non zero if any file fails to parse, ignoring the known grammar gaps below.
//
// KNOWN FALSE POSITIVES, each confirmed rather than assumed:
//
//   1. `if let x = try await f()`. Valid Swift, and this grammar rejects it while accepting the
//      identical `guard let x = try await f()`. An asymmetry like that can only be the grammar.
//   2. `nonisolated(unsafe)`. Swift 5.10 and later. The grammar accepts a bare `nonisolated`.
//   3. `OneAlarm/Views/ConnectionsHubView.swift` produces one whole-file error node. It produced the
//      same error at commit bbe0f65, which Alex built and ran on his Mac successfully, so the file
//      compiles and the grammar is what is wrong. Do not go hunting for it again.
//
// Anything not on that list is a real syntax error and should be fixed before Alex is asked to build.

const fs = require('fs');
const path = require('path');

let Parser, Swift;
try {
  Parser = require('tree-sitter');
  Swift = require('tree-sitter-swift');
} catch {
  console.error('tree-sitter not installed. Run:  npm install tree-sitter tree-sitter-swift');
  console.error('Skipping the syntax check rather than pretending it passed.');
  process.exit(2);
}

const parser = new Parser();
parser.setLanguage(Swift);

const root = path.resolve(__dirname, '..');

/// Constructs this grammar cannot parse but Swift can. A line matching one of these is not a finding.
const grammarGaps = [
  /\bif\s+(?:let|var|case)\b.*=\s*try\s+await\b/,
  /\bnonisolated\s*\(\s*unsafe\s*\)/,
];

/// Files known to fail wholesale for a grammar reason, with the evidence that says so.
const knownFiles = new Set(['OneAlarm/Views/ConnectionsHubView.swift']);

function swiftFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['.git', 'node_modules', 'build', 'DerivedData'].includes(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) swiftFiles(full, out);
    else if (entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

let checked = 0;
let real = 0;
let excused = 0;

for (const file of swiftFiles(root)) {
  checked++;
  const rel = path.relative(root, file);
  const source = fs.readFileSync(file, 'utf8');
  const lines = source.split('\n');
  const findings = [];

  (function visit(node) {
    if (node.type === 'ERROR' || node.isMissing) {
      findings.push({ line: node.startPosition.row + 1, missing: node.isMissing });
      return;
    }
    for (let i = 0; i < node.childCount; i++) visit(node.child(i));
  })(parser.parse(source).rootNode);

  for (const finding of findings) {
    const text = lines[finding.line - 1] || '';
    // The error node starts where the parser gave up, which is not where the construct it could not
    // read begins. An `if let x = try await f() { } else { }` reports at the `} else {`, six lines
    // below the cause. So the gap patterns are matched against a window, not a line.
    const window = lines.slice(Math.max(0, finding.line - 8), finding.line).join('\n');
    if (knownFiles.has(rel) || grammarGaps.some((gap) => gap.test(window))) {
      excused++;
      continue;
    }
    real++;
    console.log(`  FAIL ${rel}:${finding.line}  ${finding.missing ? 'missing token' : 'syntax error'}`);
    console.log(`       ${text.trim().slice(0, 100)}`);
  }
}

console.log(`\n  ${checked} Swift files parsed.`);
if (excused) console.log(`  ${excused} finding(s) excused as known grammar gaps, listed at the top of this file.`);

if (real) {
  console.log(`  ${real} real syntax error(s). Fix these before asking Alex to build.\n`);
  process.exit(1);
}

console.log('  No syntax errors. This is a parse, not a type check: it cannot see a wrong type,');
console.log('  a missing argument label or an unannotated literal. Those still need Xcode.\n');
