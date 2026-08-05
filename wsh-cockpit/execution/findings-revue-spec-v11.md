# Findings de revue sur la spec claude-cockpit-wrapper v11 (CodeRabbit, PR #16, 2026-08-05)

Ces cinq findings visent `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md`.
Ils ont été résolus sur la PR #16 avec un report motivé : « à traiter dans le lot
d'implémentation du wrapper avant que la spec ne devienne du code ». Les intégrer est un
prérequis du plan (fiche 0.1).

## Finding 3721135340 — docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md:135

_🗄️ Data Integrity & Integration_ | _🟠 Major_ | _🏗️ Heavy lift_

**Use no-clobber primitives for every claim transition.**

Plain `mv` replaces an existing destination. A stale `.won-<pid>` file or a concurrent adopter can therefore be overwritten, violating invariant I1 and destroying in-flight claim state.

Use a destination-exclusive rename or equivalent no-clobber protocol for source-to-`.won`, final-claim, replacement, and rollback operations. Test stale targets and concurrent A/B adoption.







Also applies to: 189-210, 264-267

## Finding 3721135346 — docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md:317

_🗄️ Data Integrity & Integration_ | _🟠 Major_ | _🏗️ Heavy lift_

**Define the `keep` state during re-adoption.**

`release` keeps `keep-<slug>`, but a later adopter can acquire the released claim without `--keep`. The claim then belongs to `claude-<runid>`, while `stop` still sees `keep-<slug>` and calls `release` instead of teardown.

The same stale marker remains when a created keep session returns to the scan pool. Remove the marker on non-keep adoption, or make keep sticky and document that default adoption does not take full ownership. Add both paths to the selftest.

## Finding 3721135353 — docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md:405

_🎯 Functional Correctness_ | _🟠 Major_ | _⚡ Quick win_

**Scope the tab query to `WAVETERM_WORKSPACEID`.**

The CTE reads every `db_workspace`. A same-named tab from another workspace can therefore match, contradicting the current-workspace-only rule in Lines 417-420.

Filter both `tabids` and `pinnedtabids` by the current workspace before matching the tab name.

## Finding 3721135358 — docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md:405

_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_

<details>
<summary>🧩 Analysis chain</summary>

🏁 Script executed:

```shell
#!/bin/bash
set -euo pipefail

# Locate and inspect the referenced spec sections.
if [ -f docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md ]; then
  wc -l docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md
  sed -n '370,435p' docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md | cat -n
else
  echo "referenced file not found"
fi

# Search for the exact SQL and :nom usages/references in the repository.
printf '\n--- :nom usages ---\n'
rg -n ':nom|json_extract\(data, '"'"'\\$.name'"'"'\)|sqlite3' docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md wsh-cockpit || true

# Behavioral probe: POSIX shell sqlite3 argument expansion with a tab-name containing quote.
printf '\n--- sqlite3 parameter probing (read-only shell simulation) ---\n'
python3 - <<'PY'
import shlex, subprocess, sys
query = r"SELECT oid FROM db_tab WHERE json_extract(data, '$.name') = :nom;"
input_name = "test'name"
full = f'echo "{query}"'
proc = subprocess.run(["/bin/sh","-c",full], text=True, capture_output=True)
print("query_injected:", "json_extract(data" in proc.stdout or ":nom" in proc.stdout, repr(proc.stdout.strip()))
print("shell_arg_quoted:", shlex.quote(input_name), "would be:", repr(input_name), "with command", "echo", repr(input_name))
PY
```

Repository: qveys/claude-skills

Length of output: 7472

---



</details>



**Security And Privacy (CWE-89):** Improper Neutralization of Special Elements used in an SQL Command ('SQL Injection')

**Reachability:** External · **Exploitability:** Moderate

**Define a real binding flow for the `:nom` parameter.**

The spec declares a parameterized query but not how `sqlite3` receives `:nom`. A direct call leaves `:nom` unset and returns no rows; escaping/interpolating it into the SQL command creates SQL-injection risk. The implementation design must require parameter binding and cover names containing quotes, `%`, and newlines.

Also applies to lines 417-423.

## Finding 3721135363 — docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md:427

_🎯 Functional Correctness_ | _🟡 Minor_ | _⚡ Quick win_

<details>
<summary>🧩 Analysis chain</summary>

🏁 Script executed:

```shell
#!/bin/bash
set -euo pipefail

echo "== file exists and size =="
wc -l docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md 2>/dev/null || true

echo "== relevant excerpt with line numbers =="
sed -n '400,445p' docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md 2>/dev/null | nl -ba -v400 || true

echo "== search duplicate tab / first match / candidates terms =="
rg -n -i "doublon|duplicate|premier match|first match|warning|candidats|candidates|ORDER BY|tab" docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md 2>/dev/null || true
```

Repository: qveys/claude-skills

Length of output: 4408

---

🏁 Script executed:

```shell
#!/bin/bash
set -euo pipefail

python3 - <<'PY'
import sqlite3
con=sqlite3.connect(':memory:')
cur=con.cursor()
cur.execute("create table tabs(id integer primary key autoincrement, name text, tab_order integer null)")
cur.executemany("insert into tabs(name,tab_order) values (?,?)", [("A",None),("A",None),("A",None)])
cur.execute("select id from tabs where name = 'A' limits 1")
print("rowids without ORDER BY:", [row[0] for row in cur.fetchall()])

cur.execute("create table tabs2(id integer primary key autoincrement, name text, tab_order integer)")
cur.executemany("insert into tabs2(name,tab_order) values (?,?)", [("A",2),("A",1),("A",3)])
cur.execute("select id from tabs2 where name = 'A' limit 1")
print("first rowid by insertion:", cur.fetchone()[0])
cur.execute("select id from tabs2 where name = 'A' order by coalesce(tab_order,999) asc limit 1")
print("first rowid with defined tab_order:", cur.fetchone()[0])
PY
```

Repository: qveys/claude-skills

Length of output: 284

---

🏁 Script executed:

```shell
#!/bin/bash
set -euo pipefail
python3 - <<'PY'
import sqlite3, textwrap

print("== SQLite first-row deterministic check (LIMIT 1 only) ==")
con = sqlite3.connect(":memory:")
cur = con.cursor()
cur.execute("CREATE TABLE tabs(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
cur.executemany("INSERT INTO tabs(name) VALUES (?)", [("A",), ("A",), ("A",)])
cur.execute("SELECT id FROM tabs WHERE name = 'A' LIMIT 1")
ids_no_order = sorted(tuple(row[0] for _, _ in cur.execute("SELECT id FROM tabs WHERE name = 'A' LIMIT 1")) for _ in range(10))
print([row[0] for row in cur.fetchmany(3)])
print("ids across 10 reads:", ids_no_order)

print("\n== SQLite deterministic ORDER BY examples ==")
cur.execute("CREATE TABLE tabs2(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, row_order INTEGER)")
cur.executemany("INSERT INTO tabs2(name,row_order) VALUES (?,?)", [("A",2),("A",1),("A",3)])
print("without ORDER BY:", [row[0] for row in cur.execute("SELECT id FROM tabs2 WHERE name = 'A' LIMIT 1")])
print("with ORDER BY coalesce(row_order,999) ASC:", [row[0] for row in cur.execute("SELECT id FROM tabs2 WHERE name = 'A' ORDER BY COALESCE(row_order,999) ASC LIMIT 1")])
PY
```

Repository: qveys/claude-skills

Length of output: 426

---

🏁 Script executed:

```shell
#!/bin/bash
set -euo pipefail
python3 - <<'PY'
import sqlite3

print("== SQLite first-row check with duplicates ==")
con = sqlite3.connect(":memory:")
cur = con.cursor()
cur.execute("CREATE TABLE tabs(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
cur.executemany("INSERT INTO tabs(name) VALUES (?)", [("A",), ("A",), ("A",)])
results = [set(row[0] for row in cur.execute("SELECT id FROM tabs WHERE name = 'A' LIMIT 1")) for _ in range(10)]
for row in cur.execute("SELECT id FROM tabs WHERE name = 'A' LIMIT 1"):
    print(row[0])
print("first id across 10 reads:", results)
print("all ids:", [row[0] for row in cur.execute("SELECT id FROM tabs WHERE name = 'A'")])

print("\n== SQLite deterministic ORDER BY examples ==")
cur.execute("CREATE TABLE tabs2(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, row_order INTEGER)")
cur.executemany("INSERT INTO tabs2(name,row_order) VALUES (?,?)", [("A",2),("A",1),("A",3)])
print("without ORDER BY:", [row[0] for row in cur.execute("SELECT id FROM tabs2 WHERE name = 'A' LIMIT 1")])
print("with ORDER BY row_order ASC:", [row[0] for row in cur.execute("SELECT id FROM tabs2 WHERE name = 'A' ORDER BY row_order ASC LIMIT 1")])
PY
```

Repository: qveys/claude-skills

Length of output: 401

---



</details>

**Make duplicate tab selection deterministic.**

`resolve_live_tab_cached` uses `LIMIT 1` without `ORDER BY`, so an exact “first match” ordering is not defined if the same name appears in `db_tab`. Define the order explicitly, such as workspace tab order, or reject duplicates. Include every candidate name in the warning.

