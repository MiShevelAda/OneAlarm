#!/usr/bin/env node
//
// Two things a Swift compiler knows that a parse does not: memberwise argument order, and a type
// declared twice in one module.
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

// A type declared twice in one module.
//
// "Invalid redeclaration of 'AllowlistTests'". It broke Cmd+U on 17 August: a second `AllowlistTests`
// had grown inside `AdapterMutationTests.swift` while a dedicated `AllowlistTests.swift` existed, and
// neither file was wrong on its own. Only a compiler sees the collision, and only when both are in
// the same module, which is why `OneAlarm` and `OneAlarmTests` are counted separately.
//
// The duplicate was also quietly harmful before it stopped compiling: it carried its own copy of the
// allowlist, four entries behind the real one, so it would have gone on passing while testing an
// allowlist the app does not use.
for (const module of ['OneAlarm', 'OneAlarmTests']) {
  const seen = new Map();
  for (const file of swiftFiles(path.join(root, module))) {
    const tree = trees.get(file);
    if (!tree) continue;
    for (const node of children(tree.rootNode)) {
      if (node.type !== 'class_declaration' && node.type !== 'protocol_declaration') continue;
      const name = firstOfType(node, 'type_identifier');
      if (!name) continue;
      const where = `${path.relative(root, file)}:${node.startPosition.row + 1}`;
      if (seen.has(name.text)) {
        failures++;
        console.log(`  FAIL ${where}  invalid redeclaration of '${name.text}'`);
        console.log(`       already declared at ${seen.get(name.text)}, and both are in ${module}`);
      } else {
        seen.set(name.text, where);
      }
    }
  }
}

// **A third check was written here on 17 August and removed the same hour.** It looked for assigning
// to a `let` property of the enclosing type, which broke the build twice that day: a SwiftUI screen
// took its alarm list as a `let` from its parent and a button tried to refresh it, and the Whoop
// adapter tried to widen a `ResolvedTarget` whose every field is a `let`.
//
// It could not be made to fail on either real case. The guard that kept it quiet, skipping any name
// also declared `var` somewhere in the file, is exactly what swallowed them: `ConnectionsHubView.swift`
// has three different types in it and two of them declare `var choices`. Resolving that needs the
// name looked up in the type the assignment is actually inside, which the flat text scan cannot do.
//
// It is deleted rather than left in, because `docs/LEARNED.md` already carries the rule it would have
// broken: **a checker that has never failed has not been tested**, and one that reports "no problems"
// while enforcing nothing is worse than no checker, since it is read as evidence. Both cases were
// caught by reading the property declaration before writing the assignment, which is the practice
// that actually worked and costs one grep.

// An attribute separated from its declaration by a doc comment.
//
// `@ViewBuilder` followed by `/// ...` followed by a property applies the attribute to **that**
// property, silently. On 18 August a new computed property was inserted between `@ViewBuilder` and
// the view it belonged to, so the attribute landed on a `[String]` and the build failed with
// "Static method 'buildExpression' requires that '[String]' conform to 'View'", which names neither
// the attribute nor the property that lost it.
//
// Legal Swift, so the parser cannot see it. Always a mistake, because an attribute belongs against
// its declaration or above the doc comment, never between the two. Cheap to detect and it just cost
// a build.
for (const [file] of trees) {
  const rel = path.relative(root, file);
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  for (let i = 0; i < lines.length - 1; i++) {
    if (!/^\s*@[A-Za-z_]\w*(\(|\s*$)/.test(lines[i])) continue;
    // **The attribute has to be ALONE on its line.** `@Environment(Store.self) private var store`
    // carries its own declaration, so a doc comment underneath belongs to whatever comes next and
    // nothing is orphaned. Without this the check fired on that shape, which is the most common
    // property declaration in this codebase: a false positive on nearly every SwiftUI view, and a
    // checker that cries wolf is one somebody switches off.
    if (/\b(var|let|func|struct|class|enum|init)\b/.test(lines[i])) continue;
    if (!/^\s*\/\/\//.test(lines[i + 1])) continue;
    failures++;
    console.log(`  FAIL ${rel}:${i + 1}  attribute separated from its declaration by a doc comment`);
    console.log(`       ${lines[i].trim()}`);
    console.log('       Move it directly above the declaration, or above the doc comment.');
  }
}

// A standard library method called without its required argument label.
//
// `pair.weekdays.subtracting(own).isSubset(othersCover)` broke Alex's build on 20 August:
// "Missing argument label 'of:' in call". The parse is perfectly happy, the types are right, and the
// only thing wrong is a word. Fourth class of error to reach his Xcode that nothing here could see.
//
// Deliberately a **fixed list**, not a general check. Knowing which labels a method requires needs
// type information a parse does not have, so this covers only the handful this codebase actually
// uses, where the label is mandatory and the mistake is silent until a compiler speaks. Add to the
// list when something new bites, rather than trying to be clever.
const LABELLED_METHODS = [
  ['isSubset', 'of'],
  ['isStrictSubset', 'of'],
  ['isSuperset', 'of'],
  ['isStrictSuperset', 'of'],
  ['isDisjoint', 'with'],
  ['symmetricDifference', null],
  ['starts', 'with'],
];

for (const [file] of trees) {
  const rel = path.relative(root, file);
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  for (const [method, label] of LABELLED_METHODS) {
    if (!label) continue;
    for (let i = 0; i < lines.length; i++) {
      // `.isSubset(` where the next thing is not `of:`. Comments are skipped, because this file and
      // its neighbours discuss these calls in prose constantly.
      if (/^\s*(\/\/|\*|\/\*)/.test(lines[i])) continue;
      const pattern = new RegExp(`\\.${method}\\(\\s*(?!${label}\\s*:)`);
      if (!pattern.test(lines[i])) continue;
      failures++;
      console.log(`  FAIL ${rel}:${i + 1}  ${method}(...) needs its '${label}:' label`);
      console.log(`       ${lines[i].trim()}`);
    }
  }
}

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

console.log(`  ${checked} memberwise call site(s) checked against ${structs.size} struct(s), and every type name.`);
if (failures) {
  // Deliberately not named as one kind of error. An earlier version called every failure here an
  // "argument order error", which is the sort of small lie that sends somebody looking in the wrong
  // place for ten minutes.
  console.log(`  ${failures} error(s) above. Xcode will refuse these.`);
  process.exit(1);
}
console.log('  Argument order matches declaration order, and no type is declared twice in one module.');
