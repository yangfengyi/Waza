#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-"$ROOT/dist/waza.zip"}"
case "$OUT" in
  /*) ;;
  *) OUT="$ROOT/$OUT" ;;
esac

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

cd "$ROOT"

MANIFEST="$(mktemp)"
FILTERED_MANIFEST="$(mktemp)"
STAGE="$(mktemp -d)"
trap 'rm -f "$MANIFEST" "$FILTERED_MANIFEST"; rm -rf "$STAGE"' EXIT

git ls-files --cached --others --exclude-standard > "$MANIFEST"

awk '
  /^\.claude-plugin\// { next }
  /^\.claude\// { next }
  /^\.github\// { next }
  /^SKILL\.md$/ { next }
  /^dist\// { next }
  /^Makefile$/ { next }
  /^skills-lock\.json$/ { next }
  /^scripts\/verify-skills\.sh$/ { next }
  /^scripts\/statusline\.sh$/ { next }
  /^scripts\/setup-english-coaching\.sh$/ { next }
  /^scripts\/setup-anti-patterns\.sh$/ { next }
  /^scripts\/setup-statusline\.sh$/ { next }
  /^scripts\/package-skill\.sh$/ { next }
  /^skills\/[^\/]+\/SKILL\.md$/ { next }
  /(^|\/)__pycache__\// { next }
  /\.pyc$/ { next }
  /(^|\/)\.DS_Store$/ { next }
  { print }
' "$MANIFEST" > "$FILTERED_MANIFEST"

tar -cf - -T "$FILTERED_MANIFEST" | (cd "$STAGE" && tar -xf -)

cat > "$STAGE/SKILL.md" <<'EOF'
---
name: waza
description: 'Dispatcher for Waza engineering skills: think (architecture), design (UI), check (review/release), hunt (debugging/regression), write (prose), learn (research), read (URL/PDF fetch), health (agent config and AI maintainability audit).'
---

# Waza: Engineering Skills Dispatcher

Prefix your first line with 🥷 inline, not as its own paragraph.

You have eight skills available. Match the user's intent to the right skill, read the matching section below, and execute it.

## Routing Table

| Intent | Skill | File |
|--------|-------|------|
| New feature, architecture, "how should I design this", value judgment, executable plan | think | `skills/think/SKILL.md` |
| UI, component, page, visual interface, frontend, screenshot aesthetic complaint | design | `skills/design/SKILL.md` |
| Code review, before merge, release/publish/push/reaction follow-through, triage issues/PRs | check | `skills/check/SKILL.md` |
| Error, crash, regression, screenshot-reported defect, test failure, unexpected behavior, "why broken" | hunt | `skills/hunt/SKILL.md` |
| Writing, editing prose, polish, release notes, remove AI tone | write | `skills/write/SKILL.md` |
| Deep research, unfamiliar domain, compile sources into output | learn | `skills/learn/SKILL.md` |
| Any URL or PDF to fetch, "read this", "fetch this page" | read | `skills/read/SKILL.md` |
| Codex/Claude ignoring instructions, agent config audit, hooks/MCP broken, health token usage, AI coding code rot, unclear context, missing verification, stale verifier output | health | `skills/health/SKILL.md` |

## How This Works

1. Read the user's message and match it to a skill from the table above.
2. Read the matched skill section in full.
3. Execute that skill's instructions exactly.

If the message could match multiple skills, use these disambiguation rules:

1. Most specific wins: `/design` is more specific than `/think` for UI decisions.
2. URL in message: start with `/read`. If the content is research material, chain to `/learn`.
3. Code already done vs. code broken: done/PR -> `/check`; error/broken -> `/hunt`.
4. Config/maintainability vs. code: Codex/Claude misbehaving, hooks/MCP, `/health` token usage, AI coding code rot, unclear context, missing verification, or stale verifier output -> `/health`; user code errors -> `/hunt`.
5. Release action vs. release prose: commit/tag/publish/push/release reactions/close issue -> `/check`; write release notes/changelog text -> `/write`.
6. Screenshot taste vs. screenshot regression: visual taste complaint -> `/design`; broken render/state/generated output or used-to-work evidence -> `/hunt`.
7. From scratch vs. editing: new long-form output -> `/learn`; existing draft to polish -> `/write`.
8. "Judge this" + error -> `/hunt`; "judge this" + should we keep it -> `/think`.
9. Still ambiguous: read both skills' "Not for" sections; use exclusion. If still unclear, ask the user.

## Path Resolution

In this distribution, sub-skill scripts live at `skills/{name}/scripts/`. Resolve all relative paths from this file's directory, not from a personal home-directory skill cache.

## Chaining

Skills chain manually, not automatically. Each skill completes and waits for the user's next action.

Common chains: `/think` -> implement approved plan -> `/check` | `/hunt` -> fix -> `/check` -> release/push/issue follow-through | `/read` -> `/learn` -> `/write`
EOF

find skills -mindepth 2 -maxdepth 2 -name SKILL.md | sort | while IFS= read -r path; do
  skill="$(basename "$(dirname "$path")")"
  {
    printf '\n---\n\n# SKILL: %s\n\n' "$skill"
    awk 'BEGIN{skip=0} /^---$/{if(NR==1){skip=1;next} if(skip){skip=0;next}} !skip' "$path"
  } >> "$STAGE/SKILL.md"
done

perl -0pi -e 's#`skills/([a-z][a-z0-9_-]*)/SKILL\.md`#the **$1** section below#g' "$STAGE/SKILL.md"
find "$STAGE/skills" -type d -empty -delete 2>/dev/null || true

(cd "$STAGE" && find . -type f | sed 's#^\./##' | sort | zip -q "$OUT" -@)

if ! zipinfo -1 "$OUT" | awk '$0 == "SKILL.md" { found = 1 } END { exit found ? 0 : 1 }'; then
  echo "ERROR: root SKILL.md missing from $OUT" >&2
  exit 1
fi

SKILL_COUNT="$(zipinfo -1 "$OUT" | awk '$0 ~ /(^|\/)SKILL\.md$/ { count++ } END { print count + 0 }')"
if [ "$SKILL_COUNT" -ne 1 ]; then
  echo "ERROR: expected exactly one SKILL.md in $OUT, found $SKILL_COUNT" >&2
  exit 1
fi

SIZE=$(wc -c < "$OUT" | tr -d ' ')
echo "OK: wrote $OUT (${SIZE} bytes)"

# Post-package validation: unzip to a temp dir and verify frontmatter integrity.
VALIDATE_DIR="$(mktemp -d)"
trap 'rm -rf "$VALIDATE_DIR"' EXIT
unzip -q "$OUT" -d "$VALIDATE_DIR"

python3 - "$VALIDATE_DIR" <<'VALIDATE_PYEOF'
import sys
from pathlib import Path

stage = Path(sys.argv[1])
root_skill = stage / "SKILL.md"
if not root_skill.exists():
    print("POST-PACKAGE ERROR: SKILL.md missing from extracted ZIP", file=sys.stderr)
    raise SystemExit(1)

text = root_skill.read_text()

# Verify ninja marker is present.
if "Prefix your first line with 🥷 inline" not in text:
    print("POST-PACKAGE ERROR: root SKILL.md missing ninja prefix instruction", file=sys.stderr)
    raise SystemExit(1)

# Verify all 8 skill sections are inlined.
expected = ["think", "design", "check", "hunt", "write", "learn", "read", "health"]
for skill in expected:
    if f"# SKILL: {skill}" not in text:
        print(f"POST-PACKAGE ERROR: SKILL section '{skill}' not inlined in root SKILL.md", file=sys.stderr)
        raise SystemExit(1)

# Verify no broken references to nested SKILL.md paths remain.
if "skills/check/SKILL.md" in text or "skills/think/SKILL.md" in text:
    print("POST-PACKAGE ERROR: root SKILL.md still contains nested SKILL.md path references", file=sys.stderr)
    raise SystemExit(1)

print("ok: post-package validation passed")
VALIDATE_PYEOF
