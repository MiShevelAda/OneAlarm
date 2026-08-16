#!/usr/bin/env node
//
// Memberwise initialiser argument order.
//
// Swift builds a struct's initialiser from its stored properties **in the order they are written
// down**, and there is no other order available. Passing them in a different order is a compile
// error, "Argument 'group' must precede argument 'rawKeys'", and it is invisible to every other
// check in this project: the file parses perfectly, the types are all correct, and nothing is
// missing. Only a compiler knows.
//
// There is no Swift compiler in a session environment, which is checked rather than assumed and
// written up in `CLAUDE.md`. So this shipped broken on 17 August, was found by Alex's build, and
// cost him a round trip. It was the second build failure in a row from a class of error a parse
// cannot see, after a missing generic argument the day before.
//
// **Deliberately conservative.** It flags only when every label in a call is a known stored property
// of that struct and their relative order disagrees with the declaration. If a label is not a
// property at all, the call is going through some other initialiser and is left alone. A checker
// that cries wolf is a checker somebody switches off, and this project has already written that
// rule down twice.
//
// Known limits, none of them worth false positives to close:
//   - A struct declaring its own `init` is skipped entirely. Both initialisers exist and this cannot
//     tell which one a call meant.
//   - Only calls whose arguments are all labelled are considered.
//   - `static` and computed properties are not part of the memberwise initialiser and are excluded.

const fs = require('fs');
const path = require('path');

let Parser, Swift;
try {
  Parser = require('tree-sitter');
  Swift = require('tree-sitter-swift');
} catch {
  console.error('tree-sitter not installed. Run:  npm install');
  console.error('Skipping the argument order check rather than pretending it passed.');
  process.exit(2);
}

const parser = new Parser();
parser.setLanguage(Swift);
const root = path.resolve(__dirname, '..');

function swiftFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...swiftFiles(full));
    else if (entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

const children = (node) => {
  const out = [];
  for (let i = 0; i < node.childCount; i++) out.push(node.child(i));
  return out;
};
const firstOfType = (node, type) => children(node).find((c) => c.type === type);

/// Stored properties of one struct, in declaration order, or null if it should be skipped.
function storedProperties(body) {
  const names = [];
  for (const member of children(body)) {
    // A struct that writes its own initialiser has two, and a call site could mean either.
    if (member.type === 'function_declaration' && member.text.trimStart().match(/^(\w+\s+)*init\b/)) {
      return null;
    }
    if (member.type === 'init_declaration') return null;
    if (member.type !== 'property_declaration') continue;
    // Computed properties and `static` ones are not memberwise arguments.
    if (firstOfType(member, 'computed_property')) continue;
    const modifiers = firstOfType(member, 'modifiers');
    if (modifiers && /\b(static|class)\b/.test(modifiers.text)) continue;
    const pattern = firstOfType(member, 'pattern');
    const name = pattern && firstOfType(pattern, 'simple_identifier');
    if (name) names.push(name.text);
  }
  return names;
}

/// Every struct in the tree, keyed by its bare name. Nested types are keyed by their last component,
/// which is how the call sites spell them: `RoutinePlan.Entry(` resolves on `Entry`.
const structs = new Map();
const files = [...swiftFiles(path.join(root, 'OneAlarm')), ...swiftFiles(path.join(root, 'OneAlarmTests'))];
const trees = new Map();

for (const file of files) {
  const source = fs.readFileSync(file, 'utf8');
  const tree = parser.parse(source);
  trees.set(file, tree);
  (function visit(node) {
    if (node.type === 'class_declaration' && firstOfType(node, 'struct')) {
      const name = firstOfType(node, 'type_identifier');
      const body = firstOfType(node, 'class_body');
      if (name && body) {
        const props = storedProperties(body);
        // A name declared twice is ambiguous, so neither is checked.
        if (props === null || structs.has(name.text)) structs.set(name.text, null);
        else structs.set(name.text, props);
      }
    }
    for (const child of children(node)) visit(child);
  })(tree.rootNode);
}

/// The type a call expression names, if it names one plainly.
function calleeName(call) {
  const callee = call.child(0);
  if (!callee) return null;
  if (callee.type === 'simple_identifier') return callee.text;
  if (callee.type === 'navigation_expression') {
    const suffix = firstOfType(callee, 'navigation_suffix');
    const id = suffix && firstOfType(suffix, 'simple_identifier');
    return id ? id.text : null;
  }
  return null;
}

let failures = 0;
let checked = 0;

for (const [file, tree] of trees) {
  const rel = path.relative(root, file);
  (function visit(node) {
    if (node.type === 'call_expression') {
      const name = calleeName(node);
      const declared = name ? structs.get(name) : undefined;
      if (declared) {
        const suffix = firstOfType(node, 'call_suffix');
        const args = suffix && firstOfType(suffix, 'value_arguments');
        if (args) {
          const labels = [];
          let everyArgumentLabelled = true;
          for (const arg of children(args)) {
            if (arg.type !== 'value_argument') continue;
            // `value_argument_label`, not `simple_identifier`. The first version of this read the
            // latter, which for `id: id` picks up the **value** and for `rawKeys: Self.f(x)` finds
            // nothing at all, so every interesting call was quietly skipped and the checker passed
            // its own negative control. Caught by reintroducing the bug it was written for, which is
            // the only reason it is not still passing.
            const label = firstOfType(arg, 'value_argument_label');
            if (label) labels.push(label.text);
            else everyArgumentLabelled = false;
          }
          // Every label has to be a stored property, or this call means a different initialiser.
          const allKnown = labels.length > 0 && labels.every((l) => declared.includes(l));
          if (everyArgumentLabelled && allKnown) {
            checked++;
            const positions = labels.map((l) => declared.indexOf(l));
            const ascending = positions.every((p, i) => i === 0 || p > positions[i - 1]);
            if (!ascending) {
              failures++;
              const wrong = positions.findIndex((p, i) => i > 0 && p < positions[i - 1]);
              console.log(`  FAIL ${rel}:${node.startPosition.row + 1}  argument order in ${name}(...)`);
              console.log(`       '${labels[wrong]}' must precede '${labels[wrong - 1]}'`);
              console.log(`       ${name} declares: ${declared.join(', ')}`);
            }
          }
        }
      }
    }
    for (const child of children(node)) visit(child);
  })(tree.rootNode);
}

console.log(`  ${checked} memberwise call site(s) checked against ${structs.size} struct(s).`);
if (failures) {
  console.log(`  ${failures} argument order error(s). Xcode will refuse these.`);
  process.exit(1);
}
console.log('  Argument order agrees with declaration order everywhere it could be checked.');
