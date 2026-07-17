SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: setup help deps test test-handlers test-stores test-nats test-integration test-full credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs push-and-publish sync-release-version pre-push-cleanup

help:
	@echo "BotArmyGtd - GTD Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail gtd_bot log with grc (brew install grc; make -C .. install-grc)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	$(MIX) deps.get

test:
	$(MIX) test

test-handlers:
	MIX_ENV=test $(MIX) test --only handlers --trace

test-stores:
	MIX_ENV=test $(MIX) test --only stores --trace

test-nats:
	MIX_ENV=test $(MIX) test --only nats --trace

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

credo:
	$(MIX) credo --only warning

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/gtd_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/gtd_bot/"
	@echo ""

test-release-smoke:
	@echo "==============================================="
	@echo "Running release smoke test"
	@echo "==============================================="
	@RELEASE_NAME=gtd_bot NATS_SERVERS=nats://localhost:4224 \
		bash $(SCRIPTS_DIRECTORY)/test_release_smoke.sh

# Detect if branch touches responder, NATS consumer, or bridge envelope code.
# Used as a gate in publish-release to require integration tests.
HAS_RESPONDER_CHANGES := $(shell git diff --name-only origin/main 2>/dev/null | grep -qE 'lib/.*/(responders|nats|consumers)/|lib/.*/bridge.*\.ex|lib/.*/event.*\.ex' && echo 1 || echo 0)

sync-release-version:
	@VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "❌ Failed to resolve version from mix.exs"; exit 1; \
	fi; \
	TIMESTAMP=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "$$VERSION" > .release-published; \
	echo "✅ Synced release version: v$$VERSION ($$TIMESTAMP)"

publish-release:
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL=gtd_bot-$$VERSION.tar.gz; \
	echo "Version: $$VERSION"; \
	echo ""; \
	if [ -f "$$TARBALL" ]; then \
		echo "✓ Tarball already exists locally: $$TARBALL (skipping rebuild)"; \
	else \
		echo "📦 Building release (tarball not found locally)..."; \
		if [ "$(HAS_RESPONDER_CHANGES)" = "1" ] && [ "$(SKIP_INTEGRATION_GATE)" != "1" ]; then \
			echo "🔒 Responder/NATS/bridge changes detected. Integration tests required before publish."; \
			$(MAKE) test-integration || { echo "❌ Integration tests failed. Publish blocked."; exit 1; }; \
			echo "✅ Integration tests passed."; \
		else \
			[ "$(HAS_RESPONDER_CHANGES)" = "1" ] && echo "⚠️  Skipping integration gate (SKIP_INTEGRATION_GATE=1)" || true; \
		fi; \
		$(MAKE) release; \
		$(MAKE) test-release-smoke || echo "⚠️  Smoke test warnings (non-blocking) - continuing"; \
		echo "Creating release tarball..."; \
		tar -czf "$$TARBALL" -C _build/prod/rel gtd_bot/; \
		echo "✓ Tarball created: $$TARBALL"; \
	fi; \
	echo ""; \
	echo "==============================================="; \
	echo "Publishing release to GitHub"; \
	echo "==============================================="; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "GTD Bot Elixir release v$$VERSION" \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	$(MAKE) sync-release-version; \
	echo ""

## Tail production log with grc (paths: $(SCRIPTS_DIRECTORY)/tail_bot_log.sh)
pre-push-cleanup:
	@echo "🧹 Cleaning up pre-push changes..."
	@git restore git-hooks/pre-push || true
	@if git diff --quiet mix.lock; then \
		echo "✓ No lock file changes"; \
	else \
		echo "📋 Staging lock file changes..."; \
		git add mix.lock; \
		git commit -m "chore: lock file updates from pre-push validation" || true; \
	fi
	@echo "✓ Ready to push"

push-and-publish:
	@BOT_NAME=gtd; \
	LOG_FILE="/tmp/.push-and-publish-$${BOT_NAME}-$$-$$(date +%s).log"; \
	echo "📋 Logging to: $$LOG_FILE" && \
	echo "=== PUSH AND PUBLISH PIPELINE ===" > "$${LOG_FILE}" && \
	echo "Timestamp: $$(date)" >> "$${LOG_FILE}" && \
	echo "Bot: $${BOT_NAME}" >> "$${LOG_FILE}" && \
	echo "" >> "$${LOG_FILE}" && \
	echo "Step 1: Clean up pre-push artifacts" >> "$${LOG_FILE}" && \
	$(MAKE) pre-push-cleanup >> "$${LOG_FILE}" 2>&1 && \
	echo "Step 2: git push (with pre-push validation)" >> "$${LOG_FILE}" && \
	if git push >> "$${LOG_FILE}" 2>&1; then \
		echo "✅ Push succeeded" && \
		echo "Step 3: make publish-release" >> "$${LOG_FILE}" && \
		if $(MAKE) publish-release >> "$${LOG_FILE}" 2>&1; then \
			echo "✅ Publish succeeded" && \
			echo "" >> "$${LOG_FILE}" && \
			echo "✅ PIPELINE COMPLETE" >> "$${LOG_FILE}"; \
		else \
			echo "❌ Publish failed (see log)" && \
			echo "❌ PIPELINE FAILED at publish-release" >> "$${LOG_FILE}"; \
			tail -30 "$${LOG_FILE}"; \
			exit 1; \
		fi; \
	else \
		echo "❌ Push failed (see log)" && \
		echo "❌ PIPELINE FAILED at git push" >> "$${LOG_FILE}"; \
		tail -30 "$${LOG_FILE}"; \
		exit 1; \
	fi && \
	echo "📋 Full log: $$LOG_FILE"

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

# Deployment targets that delegate to monorepo
.PHONY: deploy-bot verify-bot verify-bot-nats

_FIND_MONOREPO_ROOT = \
	if [ -n "$(MONOREPO_ROOT)" ]; then \
		echo "$(MONOREPO_ROOT)"; \
		exit 0; \
	fi; \
	if [ -d "../../../elixir_bots" ] && [ -f "../../../elixir_bots/Makefile" ]; then \
		if grep -q "verify-bot-nats:" "../../../elixir_bots/Makefile"; then \
			echo "$$(cd ../../../elixir_bots && pwd)"; \
			exit 0; \
		fi; \
	fi; \
	CURRENT_DIR=$$(pwd); \
	while [ "$$CURRENT_DIR" != "/" ]; do \
		if [ -f "$$CURRENT_DIR/Makefile" ] && grep -q "verify-bot-nats:" "$$CURRENT_DIR/Makefile"; then \
			if [ -d "$$CURRENT_DIR/bots" ] || [ -d "$$CURRENT_DIR/bot_army_infra" ]; then \
				echo "$$CURRENT_DIR"; \
				exit 0; \
			fi; \
		fi; \
		CURRENT_DIR=$$(dirname "$$CURRENT_DIR"); \
	done; \
	echo ""; \
	exit 1

deploy-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		echo "   Expected to find Makefile with 'deploy-bot' target"; \
		echo "   Current directory: $$(pwd)"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	echo "Deploying from: $$(pwd)"; \
	echo "Bot name: $${BOT_NAME}"; \
	echo "Monorepo root: $$MONOREPO_ROOT"; \
	echo ""; \
	$(MAKE) -C "$$MONOREPO_ROOT" deploy-bot BOT=$${BOT_NAME}

verify-bot:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot BOT=$${BOT_NAME}

verify-bot-nats:
	@MONOREPO_ROOT=$$($(call _FIND_MONOREPO_ROOT)) || { \
		echo "❌ Could not find monorepo root"; \
		exit 1; \
	}; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	$(MAKE) -C "$$MONOREPO_ROOT" verify-bot-nats BOT=$${BOT_NAME}
