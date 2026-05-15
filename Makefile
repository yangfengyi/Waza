PROJECT_KEY := $(shell printf '%s' "$(CURDIR)" | sed 's|[/_]|-|g; s|^-||')

.PHONY: test verify-docs verify-scripts verify-routing smoke-statusline smoke-statusline-installer smoke-english-coaching-installer smoke-anti-patterns-installer smoke-doc-refs smoke-agent-context smoke-maintainability smoke-verifier-output smoke-verify-skills smoke-package smoke-health package

test: verify-docs verify-routing verify-scripts smoke-statusline smoke-statusline-installer smoke-english-coaching-installer smoke-anti-patterns-installer smoke-doc-refs smoke-agent-context smoke-maintainability smoke-verifier-output smoke-verify-skills smoke-package smoke-health

verify-docs:
	./scripts/verify-skills.sh

verify-routing:
	./scripts/check-routing-drift.sh

verify-scripts:
	git diff --check
	bash -n scripts/statusline.sh skills/health/scripts/collect-data.sh skills/health/scripts/check-agent-context.sh skills/health/scripts/check-doc-refs.sh skills/health/scripts/check-maintainability.sh skills/health/scripts/check-verifier-output.sh skills/read/scripts/fetch.sh scripts/setup-statusline.sh scripts/setup-english-coaching.sh scripts/setup-anti-patterns.sh skills/check/scripts/run-tests.sh scripts/package-skill.sh
	echo "bash -n: ok"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck scripts/*.sh skills/*/scripts/*.sh && echo "shellcheck: ok"; \
	else \
	  echo "shellcheck: skipped (not installed)"; \
	fi
	python3 -m py_compile skills/read/scripts/fetch_feishu.py skills/read/scripts/fetch_weixin.py
	echo "py_compile: ok"
	bash skills/health/scripts/collect-data.sh auto >/tmp/waza-collect-data.out
	echo "collect-data: ok"
	rg -n "^=== CONVERSATION SIGNALS ===$$|^=== CONVERSATION EXTRACT ===$$|^=== MCP ACCESS DENIALS ===$$" /tmp/waza-collect-data.out
	rg -n "^=== AGENT CONFIG SUMMARY ===$$|^=== AGENT INSTRUCTION SURFACE ===$$|^=== CODEX SURFACE ===$$" /tmp/waza-collect-data.out
	rg -n "^=== AI MAINTAINABILITY SUMMARY ===$$|^maintainability_status: " /tmp/waza-collect-data.out

smoke-statusline:
	@set -e; \
	tmpdir=$$(mktemp -d); \
	json1='{"context_window":{"current_usage":{"input_tokens":10},"context_window_size":100},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000},"seven_day":{"used_percentage":34,"resets_at":2000003600}}}'; \
	json2='{"context_window":{"current_usage":{"input_tokens":20},"context_window_size":100}}'; \
	json_high='{"context_window":{"current_usage":{"input_tokens":30},"context_window_size":100},"rate_limits":{"five_hour":{"used_percentage":61,"resets_at":2000000000},"seven_day":{"used_percentage":63,"resets_at":2000003600}}}'; \
	json_low='{"context_window":{"current_usage":{"input_tokens":40},"context_window_size":100},"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2000000000},"seven_day":{"used_percentage":61,"resets_at":2000003600}}}'; \
	printf '%s' "$$json1" | HOME="$$tmpdir" bash scripts/statusline.sh >/dev/null; \
	printf '%s' "$$json2" | HOME="$$tmpdir" bash scripts/statusline.sh >"$$tmpdir/out2"; \
	printf '%s' "$$json2" | HOME="$$tmpdir" bash scripts/statusline.sh >"$$tmpdir/out3"; \
	grep -q '"used_percentage": 12' "$$tmpdir/.cache/waza-statusline/last.json"; \
	printf '%s' "$$json_high" | HOME="$$tmpdir" bash scripts/statusline.sh >/dev/null; \
	printf '%s' "$$json_low" | HOME="$$tmpdir" bash scripts/statusline.sh >"$$tmpdir/out4"; \
	grep -q '5h:' "$$tmpdir/out2"; \
	grep -q '7d:' "$$tmpdir/out2"; \
	grep -q '12%' "$$tmpdir/out2"; \
	grep -q '34%' "$$tmpdir/out3"; \
	grep -q '61%' "$$tmpdir/out4"; \
	grep -q '63%' "$$tmpdir/out4"; \
	tmpdir2=$$(mktemp -d); \
	mkdir -p "$$tmpdir2/.cache/waza-statusline"; \
	printf '%s\n' '{"seven_day":{"used_percentage":63,"resets_at":2000003600}}' > "$$tmpdir2/.cache/waza-statusline/highwater.json"; \
	printf '%s' "$$json1" | HOME="$$tmpdir2" bash scripts/statusline.sh >"$$tmpdir2/out"; \
	grep -q '12%' "$$tmpdir2/out"; \
	grep -q '63%' "$$tmpdir2/out"; \
	echo "statusline smoke: ok"

smoke-statusline-installer:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		home_dir="$$tmpdir/home"; \
		bin_dir="$$tmpdir/bin"; \
		mkdir -p "$$home_dir/.claude" "$$bin_dir"; \
		ln -s "$$(command -v python3)" "$$bin_dir/python3"; \
		ln -s "$$(command -v jq)" "$$bin_dir/jq"; \
		ln -s /bin/chmod "$$bin_dir/chmod"; \
		ln -s /bin/mkdir "$$bin_dir/mkdir"; \
		printf '%s\n' '#!/bin/bash' \
			'outfile=""' \
			'while [ "$$#" -gt 0 ]; do' \
			'  if [ "$$1" = "-o" ]; then outfile="$$2"; shift 2; else shift; fi' \
			'done' \
			'printf "%s\n" "#!/bin/bash" "echo statusline" > "$$outfile"' \
			> "$$bin_dir/curl"; \
		printf '%s\n' '#!/bin/bash' \
			'echo "brew should not be called" >&2' \
			'echo "$$*" >>"$$BREW_LOG"' \
			'exit 99' \
			> "$$bin_dir/brew"; \
		chmod +x "$$bin_dir/curl" "$$bin_dir/brew"; \
		printf '%s\n' '{invalid json' > "$$home_dir/.claude/settings.json"; \
		if BREW_LOG="$$tmpdir/brew.log" PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-statusline.sh >"$$tmpdir/install.out" 2>"$$tmpdir/install.err"; then \
			echo "setup-statusline should refuse invalid JSON"; exit 1; \
		fi; \
		grep -q 'Refusing to modify it' "$$tmpdir/install.err"; \
		grep -q 'invalid json' "$$home_dir/.claude/settings.json"; \
		test ! -f "$$tmpdir/brew.log"; \
		printf '%s\n' '{"theme":"dark"}' > "$$home_dir/.claude/settings.json"; \
		BREW_LOG="$$tmpdir/brew.log" PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-statusline.sh >"$$tmpdir/install-valid.out" 2>"$$tmpdir/install-valid.err"; \
		python3 -c "import json, sys; data=json.load(open(sys.argv[1])); assert data['theme'] == 'dark'; assert data['statusLine']['command'] == 'bash ~/.claude/statusline.sh'" "$$home_dir/.claude/settings.json"; \
		test -x "$$home_dir/.claude/statusline.sh"; \
		test ! -f "$$tmpdir/brew.log"; \
		printf '%s\n' '{"statusLine":{"type":"command","command":"bash ~/foreign.sh"}}' > "$$home_dir/.claude/settings.json"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-statusline.sh </dev/null >"$$tmpdir/install-foreign.out" 2>"$$tmpdir/install-foreign.err"; \
		grep -q 'keeping existing statusline' "$$tmpdir/install-foreign.out"; \
		python3 -c "import json, sys; data=json.load(open(sys.argv[1])); assert data['statusLine']['command'] == 'bash ~/foreign.sh', data" "$$home_dir/.claude/settings.json"; \
		echo "statusline installer smoke: ok"

smoke-english-coaching-installer:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		home_dir="$$tmpdir/home"; \
		bin_dir="$$tmpdir/bin"; \
		mkdir -p "$$home_dir/.codex" "$$bin_dir"; \
		ln -s "$$(command -v python3)" "$$bin_dir/python3"; \
		ln -s /bin/mkdir "$$bin_dir/mkdir"; \
		ln -s "$$(command -v mktemp)" "$$bin_dir/mktemp"; \
		ln -s /bin/rm "$$bin_dir/rm"; \
		printf '%s\n' '#!/bin/bash' \
			'outfile=""' \
			'while [ "$$#" -gt 0 ]; do' \
			'  if [ "$$1" = "-o" ]; then outfile="$$2"; shift 2; else shift; fi' \
			'done' \
			'printf "%s\n" "## English Coaching" "" "test rule" > "$$outfile"' \
			> "$$bin_dir/curl"; \
		chmod +x "$$bin_dir/curl"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-english-coaching.sh claude-code >"$$tmpdir/claude.out"; \
		grep -q 'test rule' "$$home_dir/.claude/rules/english.md"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-english-coaching.sh codex >"$$tmpdir/codex1.out"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-english-coaching.sh codex >"$$tmpdir/codex2.out"; \
		test "$$(grep -c '<!-- Waza English Coaching: start -->' "$$home_dir/.codex/AGENTS.md")" -eq 1; \
		grep -q 'test rule' "$$home_dir/.codex/AGENTS.md"; \
		echo "English Coaching installer smoke: ok"

smoke-anti-patterns-installer:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		home_dir="$$tmpdir/home"; \
		bin_dir="$$tmpdir/bin"; \
		mkdir -p "$$home_dir/.codex" "$$bin_dir"; \
		ln -s "$$(command -v python3)" "$$bin_dir/python3"; \
		ln -s /bin/mkdir "$$bin_dir/mkdir"; \
		ln -s "$$(command -v mktemp)" "$$bin_dir/mktemp"; \
		ln -s /bin/rm "$$bin_dir/rm"; \
		printf '%s\n' '#!/bin/bash' \
			'outfile=""' \
			'while [ "$$#" -gt 0 ]; do' \
			'  if [ "$$1" = "-o" ]; then outfile="$$2"; shift 2; else shift; fi' \
			'done' \
			'printf "%s\n" "## Anti-Patterns" "" "anti-patterns rule" > "$$outfile"' \
			> "$$bin_dir/curl"; \
		chmod +x "$$bin_dir/curl"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-anti-patterns.sh claude-code >"$$tmpdir/claude.out"; \
		grep -q 'anti-patterns rule' "$$home_dir/.claude/rules/anti-patterns.md"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-anti-patterns.sh codex >"$$tmpdir/codex1.out"; \
		PATH="$$bin_dir" HOME="$$home_dir" /bin/bash scripts/setup-anti-patterns.sh codex >"$$tmpdir/codex2.out"; \
		test "$$(grep -c '<!-- Waza Anti-Patterns: start -->' "$$home_dir/.codex/AGENTS.md")" -eq 1; \
		grep -q 'anti-patterns rule' "$$home_dir/.codex/AGENTS.md"; \
		echo "Anti-Patterns installer smoke: ok"

smoke-doc-refs:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		root="$$tmpdir/project"; \
		home_dir="$$tmpdir/home"; \
		mkdir -p "$$root/docs" "$$root/.claude/rules" "$$root/.claude/skills/demo/references" "$$home_dir/.claude/rules"; \
		touch "$$root/AGENTS.md" "$$root/docs/existing.md" "$$root/.claude/skills/demo/references/info.md" "$$home_dir/.claude/rules/global.md"; \
		printf '%s\n' 'See docs/existing.md, @AGENTS.md, and ~/.claude/rules/global.md.' > "$$root/CLAUDE.md"; \
		printf '%s\n' 'Use docs/existing.md from a nested rule file.' > "$$root/.claude/rules/sample.md"; \
		printf '%s\n' 'Use references/info.md from the skill directory.' > "$$root/.claude/skills/demo/SKILL.md"; \
		HOME="$$home_dir" bash skills/health/scripts/check-doc-refs.sh "$$root" >"$$tmpdir/ok.out"; \
		grep -q 'doc references: ok' "$$tmpdir/ok.out"; \
		printf '%s\n' 'See docs/existing.md, docs/missing.md, and @MISSING.md.' > "$$root/CLAUDE.md"; \
		if HOME="$$home_dir" bash skills/health/scripts/check-doc-refs.sh "$$root" >"$$tmpdir/bad.out"; then \
			echo "doc-ref check should reject missing references"; exit 1; \
		fi; \
		grep -q 'MISSING: CLAUDE.md:1 -> docs/missing.md' "$$tmpdir/bad.out"; \
		grep -q 'MISSING: CLAUDE.md:1 -> @MISSING.md' "$$tmpdir/bad.out"; \
		echo "doc references smoke: ok"

smoke-agent-context:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		root="$$tmpdir/project"; \
		home_dir="$$tmpdir/home"; \
		mkdir -p "$$root" "$$home_dir/.codex"; \
		printf '%s\n' '## Project' 'Repository Map: source lives in src.' '## Verification' 'Run `make test`.' '## Boundaries' 'Do not rewrite unrelated modules.' > "$$root/AGENTS.md"; \
		printf '%s\n' 'global codex rule' > "$$home_dir/.codex/AGENTS.md"; \
		{ \
			printf '%s\n' 'api_key = "SHOULD_NOT_LEAK"'; \
			printf '%s\n' 'token = "TOKEN_SHOULD_NOT_LEAK"'; \
			printf '%s\n' '[features]'; \
			printf '%s\n' 'hooks = true'; \
			printf '%s\n' '[plugins."github@openai-curated"]'; \
			printf '%s\n' 'enabled = true'; \
			printf '%s\n' "[projects.\"$$root\"]"; \
			printf '%s\n' 'trust_level = "trusted"'; \
		} > "$$home_dir/.codex/config.toml"; \
		HOME="$$home_dir" bash skills/health/scripts/check-agent-context.sh "$$root" summary >"$$tmpdir/context.out"; \
		grep -q '^agent_instruction_status: PASS$$' "$$tmpdir/context.out"; \
		grep -q '^codex_status: PASS$$' "$$tmpdir/context.out"; \
		grep -q '^project_trust: exact:trusted$$' "$$tmpdir/context.out"; \
		grep -q 'api_key=\[REDACTED\]' "$$tmpdir/context.out"; \
		grep -q 'token=\[REDACTED\]' "$$tmpdir/context.out"; \
		if grep -q 'SHOULD_NOT_LEAK' "$$tmpdir/context.out"; then \
			echo "agent context leaked sensitive config"; exit 1; \
		fi; \
		printf '%s\n' '@AGENTS.md' > "$$root/CLAUDE.md"; \
		HOME="$$home_dir" bash skills/health/scripts/check-agent-context.sh "$$root" summary >"$$tmpdir/delegation.out"; \
		grep -q '^claude_delegates_to_agents: yes$$' "$$tmpdir/delegation.out"; \
		grep -q '^conflict_status: PASS$$' "$$tmpdir/delegation.out"; \
		echo "agent context smoke: ok"

smoke-maintainability:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		good="$$tmpdir/good"; \
		mkdir -p "$$good/.github/workflows" "$$good/docs" "$$good/src"; \
		printf '%s\n' '## Project' 'Repository Map: src contains runtime code.' '## Verification' 'Run `make test` before handoff.' '## Boundaries' 'Do not rewrite unrelated modules.' > "$$good/AGENTS.md"; \
		printf 'test:\n\t@echo test\n' > "$$good/Makefile"; \
		printf '%s\n' 'name: ci' 'on: [push]' 'jobs:' '  test:' '    runs-on: ubuntu-latest' '    steps:' '      - run: make test' > "$$good/.github/workflows/test.yml"; \
		printf '%s\n' 'export function ok() { return true }' > "$$good/src/app.ts"; \
		bash skills/health/scripts/check-maintainability.sh "$$good" summary >"$$tmpdir/good.out"; \
		grep -q '^maintainability_status: PASS$$' "$$tmpdir/good.out"; \
		grep -q '^verification_status: PASS$$' "$$tmpdir/good.out"; \
		bad="$$tmpdir/bad"; \
		mkdir -p "$$bad/src"; \
		ROOT="$$bad" python3 -c "import os; from pathlib import Path; p=Path(os.environ['ROOT'])/'src/huge.ts'; p.write_text('\\n'.join(f'const item{i} = {i}; // TODO fix' for i in range(1300)) + '\\n')"; \
		bash skills/health/scripts/check-maintainability.sh "$$bad" summary >"$$tmpdir/bad.out"; \
		grep -q '^maintainability_status: FAIL$$' "$$tmpdir/bad.out"; \
		grep -q 'no agent instruction surface' "$$tmpdir/bad.out"; \
		grep -q 'no executable verification command discovered' "$$tmpdir/bad.out"; \
		grep -q 'src/huge.ts' "$$tmpdir/bad.out"; \
		excluded="$$tmpdir/excluded"; \
		mkdir -p "$$excluded/src" "$$excluded/node_modules/pkg" "$$excluded/dist" "$$excluded/build"; \
		printf '%s\n' '## Project' 'Repository Map: src contains runtime code.' '## Verification' 'Run `make test`.' '## Boundaries' 'Avoid generated directories.' > "$$excluded/AGENTS.md"; \
		printf 'test:\n\t@echo test\n' > "$$excluded/Makefile"; \
		printf '%s\n' 'export const ok = true;' > "$$excluded/src/app.ts"; \
		ROOT="$$excluded" python3 -c "import os; from pathlib import Path; root=Path(os.environ['ROOT']); (root/'node_modules/pkg/big.js').write_text('\\n'.join('x' for _ in range(2000)) + '\\n'); (root/'dist/out.js').write_text('\\n'.join('x' for _ in range(2000)) + '\\n'); (root/'build/big.py').write_text('\\n'.join('x' for _ in range(2000)) + '\\n')"; \
		bash skills/health/scripts/check-maintainability.sh "$$excluded" summary >"$$tmpdir/excluded.out"; \
		if grep -qE 'node_modules|dist/out.js|build/big.py' "$$tmpdir/excluded.out"; then \
			echo "maintainability smoke should exclude generated/dependency directories"; exit 1; \
		fi; \
		wrapper="$$tmpdir/wrapper"; \
		mkdir -p "$$wrapper/.github/workflows" "$$wrapper/scripts"; \
		printf '%s\n' '## Project' 'Repository Map: scripts contains verification.' '## Verification' 'Run `./scripts/check.sh --no-format`.' '## Boundaries' 'Keep checks non-mutating.' > "$$wrapper/AGENTS.md"; \
		printf 'build:\n\t@echo build\n' > "$$wrapper/Makefile"; \
		printf '%s\n' '#!/bin/bash' 'exit 0' > "$$wrapper/scripts/check.sh"; \
		printf '%s\n' 'name: check' 'on: [push]' 'jobs:' '  check:' '    runs-on: ubuntu-latest' '    steps:' '      - run: ./scripts/check.sh --no-format' > "$$wrapper/.github/workflows/check.yml"; \
		bash skills/health/scripts/check-maintainability.sh "$$wrapper" summary >"$$tmpdir/wrapper.out"; \
		grep -q '^wrapper_status: WARN$$' "$$tmpdir/wrapper.out"; \
		grep -q 'multiple verification commands discovered but Makefile lacks check/test/verify wrapper' "$$tmpdir/wrapper.out"; \
		links="$$tmpdir/links"; \
		mkdir -p "$$links"; \
		printf '%s\n' '## Project' 'Repository Map: root docs.' '## Verification' 'Run `make test`.' '## Boundaries' 'Keep docs valid.' > "$$links/AGENTS.md"; \
		printf 'test:\n\t@echo test\n' > "$$links/Makefile"; \
		printf '%s\n' 'See [safe remove](journal/2026-03-11-safe-remove-design.md).' > "$$links/SECURITY_AUDIT.md"; \
		bash skills/health/scripts/check-maintainability.sh "$$links" deep >"$$tmpdir/links.out"; \
		grep -q '^markdown_link_status: WARN$$' "$$tmpdir/links.out"; \
		grep -q 'SECURITY_AUDIT.md:1 -> journal/2026-03-11-safe-remove-design.md' "$$tmpdir/links.out"; \
		echo "maintainability smoke: ok"

smoke-verifier-output:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		root="$$tmpdir/project"; \
		mkdir -p "$$root/src"; \
		printf '%s\n' 'golangci-lint run ./cmd/...' '/private/tmp/deleted-worktree/foo.go:12: errcheck failed' > "$$tmpdir/stale.log"; \
		bash skills/health/scripts/check-verifier-output.sh "$$root" "$$tmpdir/stale.log" >"$$tmpdir/stale.out"; \
		grep -q '^verifier_output_status: WARN$$' "$$tmpdir/stale.out"; \
		grep -q '/private/tmp/deleted-worktree/foo.go' "$$tmpdir/stale.out"; \
		grep -q 'golangci-lint cache clean' "$$tmpdir/stale.out"; \
		existing_file="/tmp/waza-verifier-existing-$$$$.go"; \
		touch "$$existing_file"; \
		printf '%s\n' "go test $$existing_file:1" > "$$tmpdir/existing.log"; \
		bash skills/health/scripts/check-verifier-output.sh "$$root" "$$tmpdir/existing.log" >"$$tmpdir/existing.out"; \
		rm -f "$$existing_file"; \
		grep -q '^verifier_output_status: PASS$$' "$$tmpdir/existing.out"; \
		if grep -q 'stale external verifier paths detected' "$$tmpdir/existing.out"; then \
			echo "verifier output should not flag existing tmp paths"; exit 1; \
		fi; \
		printf '%s\n' 'unknown verifier failed at /private/tmp/ghost/tool.out' > "$$tmpdir/unknown.log"; \
		bash skills/health/scripts/check-verifier-output.sh "$$root" "$$tmpdir/unknown.log" >"$$tmpdir/unknown.out"; \
		grep -q '^verifier_output_status: WARN$$' "$$tmpdir/unknown.out"; \
		grep -q 'rerun the verifier after removing stale temporary worktrees' "$$tmpdir/unknown.out"; \
		echo "verifier output smoke: ok"

smoke-verify-skills:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		copy_repo() { mkdir -p "$$1"; tar --exclude './.git' --exclude '.git' -cf - . | (cd "$$1" && tar -xf -); }; \
		copy_repo "$$tmpdir/repo"; \
		python3 -c "from pathlib import Path; p=Path('$$tmpdir/repo/skills/check/SKILL.md'); t=p.read_text(); t=t.replace('---\n', '', 1); i=t.find('\n---\n'); p.write_text(t[:i] + t[i+5:])"; \
		if (cd "$$tmpdir/repo" && ./scripts/verify-skills.sh >"$$tmpdir/frontmatter.out" 2>"$$tmpdir/frontmatter.err"); then \
			echo "verify-skills should reject missing frontmatter delimiters"; exit 1; \
		fi; \
		grep -q 'INVALID FRONTMATTER' "$$tmpdir/frontmatter.err"; \
		copy_repo "$$tmpdir/repo2"; \
		python3 -c "import json; p='$$tmpdir/repo2/.claude-plugin/marketplace.json'; d=json.load(open(p)); d['plugins'].append({'name':'waza-ghost','description':'x','version':'1.0.0','category':'development','source':'./skills/ghost','homepage':'https://example.com'}); open(p,'w').write(json.dumps(d, indent=2) + '\n')"; \
		if (cd "$$tmpdir/repo2" && ./scripts/verify-skills.sh >"$$tmpdir/market.out" 2>"$$tmpdir/market.err"); then \
			echo "verify-skills should reject marketplace-only entries"; exit 1; \
		fi; \
		grep -q 'MISSING SKILL DIRECTORY: ghost' "$$tmpdir/market.err"; \
		copy_repo "$$tmpdir/repo3"; \
		python3 -c "import json; p='$$tmpdir/repo3/.claude-plugin/marketplace.json'; d=json.load(open(p)); [entry.update({'source':'./skills/read'}) for entry in d['plugins'] if entry['name']=='waza-check']; open(p,'w').write(json.dumps(d, indent=2) + '\n')"; \
		if (cd "$$tmpdir/repo3" && ./scripts/verify-skills.sh >"$$tmpdir/source.out" 2>"$$tmpdir/source.err"); then \
			echo "verify-skills should reject wrong source paths"; exit 1; \
		fi; \
		grep -q 'WRONG SOURCE: waza-check' "$$tmpdir/source.err"; \
		copy_repo "$$tmpdir/repo4"; \
		python3 -c "from pathlib import Path; p=Path('$$tmpdir/repo4/skills/check/SKILL.md'); p.write_text(p.read_text() + '\n[broken](missing-target.md)\n')"; \
		if (cd "$$tmpdir/repo4" && ./scripts/verify-skills.sh >"$$tmpdir/link.out" 2>"$$tmpdir/link.err"); then \
			echo "verify-skills should reject broken markdown links"; exit 1; \
		fi; \
		grep -q 'BROKEN MARKDOWN LINK' "$$tmpdir/link.err"; \
		copy_repo "$$tmpdir/repo5"; \
		printf '\n| trigger | skills/ghost/SKILL.md |\n' >> "$$tmpdir/repo5/skills/RESOLVER.md"; \
		if (cd "$$tmpdir/repo5" && ./scripts/verify-skills.sh >"$$tmpdir/resolver.out" 2>"$$tmpdir/resolver.err"); then \
			echo "verify-skills should reject stale RESOLVER references"; exit 1; \
		fi; \
		grep -q 'RESOLVER REFERENCES MISSING SKILL: ghost' "$$tmpdir/resolver.err"; \
		copy_repo "$$tmpdir/repo6"; \
		printf '\n| Col1 | Col2 |\n| --- | --- |\n| a | b | c |\n' >> "$$tmpdir/repo6/skills/check/SKILL.md"; \
		if (cd "$$tmpdir/repo6" && ./scripts/verify-skills.sh >"$$tmpdir/pipe.out" 2>"$$tmpdir/pipe.err"); then \
			echo "verify-skills should reject unescaped pipe in table data row"; exit 1; \
		fi; \
		grep -q 'UNESCAPED PIPE IN TABLE' "$$tmpdir/pipe.err"; \
		copy_repo "$$tmpdir/repo7"; \
		python3 -c "import json; p='$$tmpdir/repo7/.claude-plugin/marketplace.json'; d=json.load(open(p)); [e.update({'version':'3.0.0'}) for e in d['plugins'] if e['name']=='waza']; open(p,'w').write(json.dumps(d, indent=2) + '\n')"; \
		if (cd "$$tmpdir/repo7" && ./scripts/verify-skills.sh >"$$tmpdir/bundle.out" 2>"$$tmpdir/bundle.err"); then \
			echo "verify-skills should reject stale bundle version"; exit 1; \
		fi; \
		grep -q 'BUNDLE VERSION STALE' "$$tmpdir/bundle.err"; \
		echo "verify-skills smoke: ok"

package:
	./scripts/package-skill.sh

smoke-package:
	@set -e; \
		tmpdir=$$(mktemp -d); \
		./scripts/package-skill.sh "$$tmpdir/waza.zip" >/dev/null; \
		zipinfo -1 "$$tmpdir/waza.zip" >"$$tmpdir/manifest"; \
		grep -qx 'SKILL.md' "$$tmpdir/manifest"; \
		if grep -qiE '(^|/)skill\.md$$' "$$tmpdir/manifest" | grep -cv '^SKILL\.md$$' >/dev/null 2>&1; then true; fi; \
		test "$$(zipinfo -1 "$$tmpdir/waza.zip" | grep -ciE '(^|/)skill\.md$$')" -eq 1; \
		grep -qx 'skills/read/scripts/fetch.sh' "$$tmpdir/manifest"; \
		grep -qx 'skills/health/scripts/check-agent-context.sh' "$$tmpdir/manifest"; \
		grep -qx 'skills/health/scripts/check-doc-refs.sh' "$$tmpdir/manifest"; \
		grep -qx 'skills/health/scripts/check-maintainability.sh' "$$tmpdir/manifest"; \
		grep -qx 'skills/health/scripts/check-verifier-output.sh' "$$tmpdir/manifest"; \
		grep -qx 'skills/health/agents/inspector-maintainability.md' "$$tmpdir/manifest"; \
		unzip -p "$$tmpdir/waza.zip" SKILL.md | grep -q 'SKILL: check'; \
		if unzip -p "$$tmpdir/waza.zip" SKILL.md | grep -q 'skills/check/SKILL.md'; then \
			echo "package root should not reference nested SKILL.md"; exit 1; \
		fi; \
		echo "package smoke: ok"

smoke-health:
	@set -e; \
		tmpdir=$$(mktemp -d); \
	convo_dir="$$tmpdir/.claude/projects/-$(PROJECT_KEY)"; \
	mkdir -p "$$convo_dir"; \
	printf '%s\n' '{"type":"user","message":{"content":"Please build a dashboard for sales data."}}' > "$$convo_dir/2-old.jsonl"; \
	printf '%s\n' '{"type":"user","message":{"content":"Please do not use em dashes next time."}}' >> "$$convo_dir/2-old.jsonl"; \
	printf '%s\n' '{"type":"user","message":{"content":"active session placeholder"}}' > "$$convo_dir/1-active.jsonl"; \
	HOME="$$tmpdir" bash skills/health/scripts/collect-data.sh auto > "$$tmpdir/health.out"; \
	grep -q '^=== CONVERSATION SIGNALS ===$$' "$$tmpdir/health.out"; \
	grep -q '^=== AGENT CONFIG SUMMARY ===$$' "$$tmpdir/health.out"; \
	grep -q '^=== AI MAINTAINABILITY SUMMARY ===$$' "$$tmpdir/health.out"; \
	grep -q '^USER CORRECTION: Please do not use em dashes next time\.$$' "$$tmpdir/health.out"; \
	if grep -q '^USER CORRECTION: Please build a dashboard for sales data\.$$' "$$tmpdir/health.out"; then \
		echo "false positive correction detected"; exit 1; \
	fi; \
	echo "health smoke: ok"
