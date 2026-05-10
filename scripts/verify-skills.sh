#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PYEOF'
import json
import sys
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_frontmatter(path: Path) -> dict[str, str]:
    lines = path.read_text().splitlines()
    if not lines or lines[0] != "---":
        fail(f"INVALID FRONTMATTER: {path} must start with ---")

    try:
        end = lines.index("---", 1)
    except ValueError:
        fail(f"INVALID FRONTMATTER: {path} missing closing ---")

    frontmatter = lines[1:end]
    fields: dict[str, str] = {}
    in_metadata = False

    for line in frontmatter:
        if line.startswith("name:"):
            fields["name"] = line.split(":", 1)[1].strip()
            in_metadata = False
        elif line.startswith("description:"):
            raw_value = line.split(":", 1)[1].strip()
            if not raw_value.startswith('"') and ": " in raw_value:
                fail(
                    f"UNQUOTED DESCRIPTION WITH COLON: {path}\n"
                    f"  Description contains ': ' and must be wrapped in double quotes, "
                    f"otherwise YAML plain-scalar parsing truncates the field."
                )
            fields["description"] = raw_value.strip('"')
            in_metadata = False
        elif line.startswith("when_to_use:"):
            raw_value = line.split(":", 1)[1].strip()
            fields["when_to_use"] = raw_value.strip('"')
            in_metadata = False
        elif line == "metadata:":
            in_metadata = True
        elif in_metadata and line.startswith("  version:"):
            fields["version"] = line.split(":", 1)[1].strip().strip('"')
        elif line and not line.startswith(" "):
            in_metadata = False

    for field in ("name", "description", "version"):
        if not fields.get(field):
            fail(f"MISSING {field}: in {path}")

    return fields


root = Path(".")
skill_files = sorted((root / "skills").glob("*/SKILL.md"))
if not skill_files:
    fail("NO SKILLS FOUND: expected skills/*/SKILL.md")

skill_versions: dict[str, str] = {}
skill_descriptions: dict[str, str] = {}
for path in skill_files:
    skill_dir = path.parent.name
    fields = parse_frontmatter(path)
    if fields["name"] != skill_dir:
        fail(f"NAME MISMATCH: {path} frontmatter name={fields['name']} dir={skill_dir}")
    expected_prefix = "Prefix your first line with 🥷 inline, not as its own paragraph."
    if expected_prefix not in path.read_text():
        fail(
            f"MISSING NINJA PREFIX INSTRUCTION: {path}\n"
            f"  Every SKILL.md must carry this exact line:\n"
            f"  {expected_prefix}"
        )
    skill_versions[skill_dir] = fields["version"]
    skill_descriptions[skill_dir] = fields["description"]
    print(f"ok: {path.as_posix()}")

marketplace = json.load(open(root / ".claude-plugin" / "marketplace.json"))
plugins = marketplace.get("plugins")
if not isinstance(plugins, list):
    fail("INVALID MARKETPLACE: plugins must be a list")

# Marketplace shape:
#   - One bundle entry: name == "waza", source == "./". Auto-discovers all
#     skills/<dir>/SKILL.md and registers them under the waza namespace
#     (/waza:think, /waza:check, ...).
#   - Per-skill entries: name == "waza-<skill>", source == "./skills/<skill>".
#     Each registers a single skill, callable as /waza-<skill>:<skill>.
# Per-skill entries are keyed by skill_name (the dir under skills/) so version
# and description checks line up with skill_versions / skill_descriptions.
def parse_version(v: str) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in v.split("."))
    except ValueError:
        fail(f"INVALID VERSION: {v!r} must be dot-separated integers")


market_versions: dict[str, str] = {}
market_descriptions: dict[str, str] = {}
seen_names: set[str] = set()
bundle_version = ""
for entry in plugins:
    if not isinstance(entry, dict):
        fail("INVALID MARKETPLACE: plugin entry must be an object")
    name = entry.get("name")
    version = entry.get("version")
    source = entry.get("source")
    description = entry.get("description", "").strip().strip('"')
    if not name or not version:
        fail("INVALID MARKETPLACE: every plugin needs name and version")
    if not description:
        fail(f"MISSING DESCRIPTION: marketplace plugin {name}")
    if name in seen_names:
        fail(f"DUPLICATE MARKETPLACE ENTRY: {name}")
    seen_names.add(name)

    if name == "waza":
        # Duplicate bundle is already caught by the generic seen_names check
        # above (any second entry with the same name fails first).
        if source != "./":
            fail(f"WRONG BUNDLE SOURCE: source={source!r} expected='./'")
        bundle_version = version
        continue

    if not name.startswith("waza-"):
        fail(
            f"INVALID PLUGIN NAME: {name!r} must be 'waza' (bundle) or "
            f"'waza-<skill>' (per-skill entry)"
        )
    skill_name = name.removeprefix("waza-")
    if not skill_name:
        fail(
            f"INVALID PLUGIN NAME: {name!r} has an empty <skill> suffix; "
            f"per-skill entries must be named 'waza-<skill>' with a non-empty skill name"
        )
    expected_source = f"./skills/{skill_name}"
    if source != expected_source:
        fail(f"WRONG SOURCE: {name} source={source!r} expected={expected_source!r}")
    market_versions[skill_name] = version
    market_descriptions[skill_name] = description

if "waza" not in seen_names:
    fail(
        "MISSING BUNDLE ENTRY: marketplace.json must include a 'waza' bundle entry "
        "(name=\"waza\", source=\"./\") so /plugin install waza@waza registers "
        "all skills under the waza namespace"
    )

missing_from_market = sorted(set(skill_versions) - set(market_versions))
if missing_from_market:
    fail("NOT IN MARKETPLACE: " + ", ".join(missing_from_market))

extra_in_market = sorted(set(market_versions) - set(skill_versions))
if extra_in_market:
    fail("MISSING SKILL DIRECTORY: " + ", ".join(extra_in_market))

for skill, skill_version in sorted(skill_versions.items()):
    market_version = market_versions[skill]
    if skill_version != market_version:
        fail(f"VERSION MISMATCH: {skill} SKILL={skill_version} MARKET={market_version}")
    # marketplace description may append TRIGGER/SKIP lines after the
    # core SKILL.md description, so check prefix containment, not exact match.
    if not market_descriptions[skill].startswith(skill_descriptions[skill]):
        fail(
            f"DESCRIPTION MISMATCH: {skill}\n"
            f"  SKILL.md:    {skill_descriptions[skill]}\n"
            f"  marketplace: {market_descriptions[skill]}\n"
            f"  marketplace description must start with the SKILL.md description"
        )
    print(f"ok: {skill} {skill_version}")

# Bundle version must keep up with the highest per-skill version. Otherwise
# /plugin update waza@waza on a stale bundle silently ships old skill metadata.
if bundle_version and skill_versions:
    max_skill = max(skill_versions.items(), key=lambda kv: parse_version(kv[1]))
    if parse_version(bundle_version) < parse_version(max_skill[1]):
        fail(
            f"BUNDLE VERSION STALE: waza bundle={bundle_version} "
            f"is below highest skill {max_skill[0]}={max_skill[1]}.\n"
            f"  Bump the 'waza' entry in .claude-plugin/marketplace.json "
            f"to at least {max_skill[1]} so /plugin install waza@waza "
            f"matches the latest skill releases."
        )
    print(f"ok: bundle version {bundle_version} >= max skill {max_skill[1]}")

import re
# Direct local references: `references/foo.md`, `agents/bar.md`, `scripts/baz.sh`
# Lookbehind excludes absolute path fragments like $HOME/.agents/skills/X
ref_pattern = re.compile(r'(?<![/.])\b(?:references|agents|scripts)/[\w/.-]+\b')
# Script references via runtime variable: ${SKILL_DIR}/scripts/foo.sh
script_pattern = re.compile(r'\}/scripts/([\w/.-]+)')
for path in skill_files:
    skill_dir = path.parent.name
    text = path.read_text()
    refs = set(ref_pattern.findall(text))
    refs |= {"scripts/" + s for s in script_pattern.findall(text)}
    for ref in sorted(refs):
        expected = root / "skills" / skill_dir / ref
        if not expected.exists():
            fail(f"BROKEN REFERENCE: {path} references {ref} but file does not exist")
        print(f"ok: reference {skill_dir}/{ref}")

# Description conformance: every skill needs a triggerable opening, a "Not for"
# exclusion clause, and a sane length. Locks the convention so new skills can't
# drift into vague descriptions that the Claude Code resolver can't match.
for skill, description in sorted(skill_descriptions.items()):
    clean = description.strip().strip('"')
    length = len(clean)
    if length < 40:
        fail(f"DESCRIPTION TOO SHORT: {skill} ({length} chars); need ≥40 for reliable resolver matching")
    if length > 500:
        fail(f"DESCRIPTION TOO LONG: {skill} ({length} chars); trim to ≤500 to keep the resolver index light")
    # Descriptions should be third-person (per Anthropic best practices).
    # Check for a verb in the first word rather than enforcing specific starters.
    first_word = clean.split()[0].lower() if clean.split() else ""
    passive_starters = ("the", "a", "an", "this", "it")
    if first_word in passive_starters:
        fail(
            f"DESCRIPTION STARTS WITH ARTICLE: {skill}\n"
            f"  Start with a verb or action phrase (third-person). Got: {clean[:60]!r}"
        )
    if "not for" not in clean.lower():
        fail(
            f"DESCRIPTION MISSING EXCLUSION CLAUSE: {skill}\n"
            f"  Must contain a 'Not for ...' clause so the resolver learns when NOT to fire. Got: {clean[:120]!r}"
        )
    print(f"ok: description {skill} ({length} chars)")

# Durable context rules must stay portable and evidence-bound. They are useful
# as private task context, but cannot bake in one machine's memory path or
# replace current-state verification.
personal_path_pattern = re.compile(r'/(?:Users|home)/[A-Za-z0-9._-]+/')
durable_context_skills = {"think", "check", "hunt", "design", "write", "health"}
for path in skill_files:
    skill = path.parent.name
    text = path.read_text()
    if personal_path_pattern.search(text):
        fail(
            f"PERSONAL ABSOLUTE PATH IN SKILL: {path}\n"
            f"  Skill docs must not hard-code personal home-directory paths. "
            f"Use user-provided paths, project-relative paths, or resolver commands instead."
        )

    has_section = "## Durable Context Preflight" in text
    if skill in durable_context_skills and not has_section:
        fail(
            f"MISSING DURABLE CONTEXT PREFLIGHT: {path}\n"
            f"  This skill must explain how to consume optional memory/preview context."
        )
    if not has_section:
        continue

    section = text.split("## Durable Context Preflight", 1)[1]
    section = section.split("\n## ", 1)[0].lower()
    if "current state" not in section or "override" not in section:
        fail(
            f"DURABLE CONTEXT NOT EVIDENCE-BOUND: {path}\n"
            f"  Memory/context rules must say current state is verified and overrides stale memory."
        )
    if "raw transcripts" not in section:
        fail(
            f"DURABLE CONTEXT MAY OVERREAD: {path}\n"
            f"  Durable context rules must forbid reading raw transcripts by default."
        )
    print(f"ok: durable context preflight for {skill}")

# RESOLVER.md coverage: every skill must be referenced from the central routing
# table at skills/RESOLVER.md. Keeps the human-readable index in lock-step with
# the SKILL.md descriptions the model actually sees.
resolver_path = root / "skills" / "RESOLVER.md"
if not resolver_path.exists():
    fail(f"MISSING RESOLVER: expected {resolver_path}")
resolver_text = resolver_path.read_text()
for skill in sorted(skill_versions):
    token = f"skills/{skill}/SKILL.md"
    if token not in resolver_text:
        fail(
            f"RESOLVER GAP: {skill} has no entry in {resolver_path}\n"
            f"  Add a row to a triggers table that references {token!r}."
        )
    print(f"ok: resolver entry for {skill}")

# Reverse check: RESOLVER.md references must point to existing skill dirs.
referenced_skills = set(re.findall(r'skills/([a-z][a-z0-9_-]*)/SKILL\.md', resolver_text))
stale = sorted(referenced_skills - set(skill_versions))
if stale:
    fail(f"RESOLVER REFERENCES MISSING SKILL: {', '.join(stale)}")
print("ok: resolver has no stale skill references")

# Collect all markdown files for link and table checks.
all_md: list[Path] = [resolver_path]
for skill in sorted(skill_versions):
    skill_root = root / "skills" / skill
    all_md.append(skill_root / "SKILL.md")
    for sub in ("references", "agents"):
        sub_dir = skill_root / sub
        if sub_dir.is_dir():
            all_md.extend(sorted(sub_dir.rglob("*.md")))

# Broken link check: relative [text](path) links must resolve.
link_re = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
URL_PREFIXES = ("http://", "https://", "mailto:", "ftp://", "tel:", "data:")
for path in all_md:
    if not path.exists():
        continue
    in_code = False
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        if line.lstrip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        for m in link_re.finditer(line):
            raw = m.group(1).strip()
            if not raw or raw.startswith(("#", "/")):
                continue
            if raw.startswith(URL_PREFIXES) or "://" in raw:
                continue
            target = raw.split("#", 1)[0].split("?", 1)[0]
            if target and not (path.parent / target).resolve().exists():
                fail(f"BROKEN MARKDOWN LINK: {path}:{lineno} -> {raw}")
    print(f"ok: markdown links {path.relative_to(root)}")

# Pipe-in-table: unescaped | in data cells breaks GitHub rendering (#35).
SEP_RE = re.compile(r'^[\s|:\-]+$')

def pipe_count(s: str) -> int:
    n, tick, i = 0, False, 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            i += 2
            continue
        if s[i] == "`":
            tick = not tick
        elif s[i] == "|" and not tick:
            n += 1
        i += 1
    return n

for path in all_md:
    if not path.exists():
        continue
    in_fence = False
    sep_pipes = None
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            sep_pipes = None
            continue
        if in_fence:
            sep_pipes = None
            continue
        if SEP_RE.match(stripped) and "---" in stripped and "|" in stripped:
            sep_pipes = pipe_count(stripped)
            continue
        if sep_pipes is not None and stripped.startswith("|"):
            if pipe_count(stripped) > sep_pipes:
                fail(
                    f"UNESCAPED PIPE IN TABLE: {path}:{lineno}\n"
                    f"  Use '\\|' or wrap the cell text in backticks."
                )
            continue
        sep_pipes = None
    print(f"ok: table pipes {path.relative_to(root)}")

# The source tree must not have a root SKILL.md. A root skill causes
# `npx skills add tw93/Waza` to stop scanning nested skills, so the direct
# coding install path would expose only `/waza`. Claude Desktop's single-root
# SKILL.md is generated by scripts/package-skill.sh during release packaging.
root_skill = root / "SKILL.md"
if root_skill.exists():
    fail("ROOT SKILL DISALLOWED: generate the Desktop dispatcher during packaging instead")
print("ok: no root SKILL.md")
PYEOF

# Rules files (outside skills/ so regex check above does not cover them)
test -f rules/english.md && \
test -f rules/chinese.md && \
test -f rules/anti-patterns.md && echo "references: ok"

if ! grep -Fq "npx skills add tw93/Waza -a claude-code -g -y" README.md; then
    echo "README INSTALL COMMAND: Waza install must use the default direct-skill command" >&2
    exit 1
fi
echo "ok: README installs nested skills"

if ! grep -Fq "Chinese-only messages" rules/english.md || \
   ! grep -Fq "already-natural English, stay silent" rules/english.md; then
    echo "ENGLISH COACHING GUARD: rules/english.md must suppress Chinese-only and no-op correction output" >&2
    exit 1
fi
echo "ok: English Coaching guard"

# Attribution leak hardstop: no AI attribution strings in tracked markdown or scripts.
# These strings indicate AI-generated co-authorship leaked into skill content.
ATTRIBUTION_PATTERNS="Co-Authored-By: Claude\|Co-authored-by: Cursor\|noreply@anthropic.com\|cursoragent@cursor.com"
# Scan only non-documentation files: skip SKILL.md, rules/*.md, and this script
# (those legitimately document what patterns to detect rather than leaking them).
if grep -rn --include="*.sh" --include="*.json" "$ATTRIBUTION_PATTERNS" . 2>/dev/null \
   | grep -v "^Binary\|\.git/" \
   | grep -v "scripts/verify-skills.sh"; then
    echo "ATTRIBUTION LEAK: AI attribution string found in tracked script or config." >&2
    exit 1
fi
echo "ok: no attribution leak"

# Pairwise trigger keyword overlap: detect when two skills share trigger keywords
# (Jaccard similarity >= 0.5 means more than half the combined keywords are shared).
python3 - <<'OVERLAP_PYEOF'
import sys
from pathlib import Path

root = Path(".")
skill_files = sorted((root / "skills").glob("*/SKILL.md"))

def parse_when_to_use(path):
    for line in path.read_text().splitlines():
        if line.startswith("when_to_use:"):
            raw = line.split(":", 1)[1].strip().strip('"')
            return {kw.strip().lower() for kw in raw.split(",") if kw.strip()}
    return set()

skills = {}
for path in skill_files:
    name = path.parent.name
    skills[name] = parse_when_to_use(path)

names = sorted(skills)
found_overlap = False
for i, a in enumerate(names):
    for b in names[i+1:]:
        shared = skills[a] & skills[b]
        union = skills[a] | skills[b]
        if not union:
            continue
        jaccard = len(shared) / len(union)
        if jaccard >= 0.5:
            print(f"TRIGGER OVERLAP: {a} vs {b} jaccard={jaccard:.2f} shared={sorted(shared)}", file=sys.stderr)
            found_overlap = True

if found_overlap:
    raise SystemExit(1)
print("ok: trigger keyword overlap below threshold")
OVERLAP_PYEOF
