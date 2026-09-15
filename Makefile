.PHONY: all clean test test-list-json test-create-config test-recipes test-live dev-setup FORCE

NIMFLAGS = -d:release --opt:size
NIM_TEST_FLAGS ?= --hints:off
TEST_SRC = cmd/ocdev/tests
RECIPE_TEST_BINS = bin/test_recipes bin/test_cli_recipes bin/test_recipe_engine \
	bin/fake_incus_cli bin/fake_incus_engine bin/recipe_engine_harness
TEST_BINS = $(RECIPE_TEST_BINS) bin/test_all bin/test_list_json bin/fake_incus_list \
	bin/test_process_support bin/process_probe bin/test_create_config bin/fake_incus_create_config
# The recipe CLI includes a maintained YAML parser; keep its release budget explicit.
MAX_BINARY_BYTES ?= 2097152

all: bin/ocdev

bin/ocdev: cmd/ocdev/src/ocdev.nim cmd/ocdev/src/*.nim
	cd cmd/ocdev && nim c $(NIMFLAGS) -o:../../bin/ocdev src/ocdev.nim

bin/ocdev-debug: cmd/ocdev/src/ocdev.nim cmd/ocdev/src/*.nim
	cd cmd/ocdev && nim c -o:../../bin/ocdev-debug src/ocdev.nim

# Always invoke Nim for tests: its cache tracks transitive Atlas dependencies
# and compiler configuration that Make's source timestamps alone cannot cover.
FORCE:

# Controllers and fake executables inherit the project-local Atlas nim.cfg.
bin/test_%: $(TEST_SRC)/test_%.nim FORCE
	mkdir -p bin
	nim c $(NIM_TEST_FLAGS) --out:$@ $<

bin/fake_incus_%: $(TEST_SRC)/fixtures/fake_incus_%.nim FORCE
	mkdir -p bin
	nim c $(NIM_TEST_FLAGS) --out:$@ $<

bin/recipe_engine_harness: $(TEST_SRC)/fixtures/recipe_engine_harness.nim FORCE
	mkdir -p bin
	nim c $(NIM_TEST_FLAGS) --path:cmd/ocdev/src --out:$@ $<

bin/process_probe: $(TEST_SRC)/fixtures/process_probe.nim FORCE
	mkdir -p bin
	nim c $(NIM_TEST_FLAGS) --out:$@ $<

# Default tests use Nim only and never contact a live Incus daemon.
test: bin/ocdev $(TEST_BINS)
	bin/test_all
	bin/test_process_support "$(abspath bin/process_probe)"
	bin/test_recipes
	bin/test_list_json "$(abspath bin/ocdev)" "$(abspath bin/fake_incus_list)"
	bin/test_create_config "$(abspath bin/ocdev)" "$(abspath bin/fake_incus_create_config)"
	bin/test_cli_recipes "$(abspath bin/ocdev)" "$(abspath bin/fake_incus_cli)"
	bin/test_recipe_engine "$(abspath bin/recipe_engine_harness)" "$(abspath bin/fake_incus_engine)"

test-recipes: bin/ocdev $(RECIPE_TEST_BINS)
	bin/test_recipes
	bin/test_cli_recipes "$(abspath bin/ocdev)" "$(abspath bin/fake_incus_cli)"
	bin/test_recipe_engine "$(abspath bin/recipe_engine_harness)" "$(abspath bin/fake_incus_engine)"

test-live: bin/ocdev
	@test "$$OCDEV_LIVE_TESTS" = 1 || (echo 'Set OCDEV_LIVE_TESTS=1 to authorize live container operations'; exit 1)
	bash cmd/ocdev/tests/recipe_smoke.sh

# Read-only CLI coverage using fake Incus (no daemon required).
test-list-json: bin/ocdev bin/test_list_json bin/fake_incus_list
	bin/test_list_json "$(abspath bin/ocdev)" "$(abspath bin/fake_incus_list)"

test-create-config: bin/ocdev bin/test_create_config bin/fake_incus_create_config
	bin/test_create_config "$(abspath bin/ocdev)" "$(abspath bin/fake_incus_create_config)"

clean:
	rm -f bin/ocdev bin/ocdev-debug bin/test-all bin/test-recipes $(TEST_BINS)
	rm -rf cmd/ocdev/deps/pkgs
	find cmd/ocdev -name "*.o" -delete

# Development helpers
dev-setup:
	cd cmd/ocdev && atlas init && atlas install

size-check: bin/ocdev
	@echo "Binary size: $$(du -h bin/ocdev | cut -f1)"
	@size=$$(stat -c%s bin/ocdev 2>/dev/null || stat -f%z bin/ocdev); \
	if [ $$size -gt $(MAX_BINARY_BYTES) ]; then \
		echo "WARNING: Binary exceeds $(MAX_BINARY_BYTES)-byte target"; \
	fi
