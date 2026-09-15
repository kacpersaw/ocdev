.PHONY: all clean test test-list-json test-recipes test-live dev-setup

NIMFLAGS = -d:release --opt:size
# The recipe CLI includes a maintained YAML parser; keep its release budget explicit.
MAX_BINARY_BYTES ?= 2097152

all: bin/ocdev

bin/ocdev: cmd/ocdev/src/ocdev.nim cmd/ocdev/src/*.nim
	cd cmd/ocdev && nim c $(NIMFLAGS) -o:../../bin/ocdev src/ocdev.nim

bin/ocdev-debug: cmd/ocdev/src/ocdev.nim cmd/ocdev/src/*.nim
	cd cmd/ocdev && nim c -o:../../bin/ocdev-debug src/ocdev.nim

# Default tests never contact a live Incus daemon.
test: bin/ocdev
	nim c -r --out:bin/test-all cmd/ocdev/tests/test_all.nim
	nim c -r --out:bin/test-recipes cmd/ocdev/tests/test_recipes.nim
	python3 cmd/ocdev/tests/test_list_json.py ./bin/ocdev
	python3 cmd/ocdev/tests/test_cli_recipes.py ./bin/ocdev
	python3 cmd/ocdev/tests/test_recipe_engine.py

test-recipes: bin/ocdev
	nim c -r --out:bin/test-recipes cmd/ocdev/tests/test_recipes.nim
	python3 cmd/ocdev/tests/test_cli_recipes.py ./bin/ocdev
	python3 cmd/ocdev/tests/test_recipe_engine.py

test-live: bin/ocdev
	@test "$$OCDEV_LIVE_TESTS" = 1 || (echo 'Set OCDEV_LIVE_TESTS=1 to authorize live container operations'; exit 1)
	bash cmd/ocdev/tests/recipe_smoke.sh

# Read-only CLI coverage using fake Incus (no daemon required).
test-list-json: bin/ocdev
	python3 cmd/ocdev/tests/test_list_json.py ./bin/ocdev

clean:
	rm -f bin/ocdev bin/ocdev-debug
	rm -rf cmd/ocdev/deps/pkgs
	find cmd/ocdev -name "*.o" -delete

# Development helpers
dev-setup:
	cd cmd/ocdev && nimble install --depsOnly -y

size-check: bin/ocdev
	@echo "Binary size: $$(du -h bin/ocdev | cut -f1)"
	@size=$$(stat -c%s bin/ocdev 2>/dev/null || stat -f%z bin/ocdev); \
	if [ $$size -gt $(MAX_BINARY_BYTES) ]; then \
		echo "WARNING: Binary exceeds $(MAX_BINARY_BYTES)-byte target"; \
	fi
