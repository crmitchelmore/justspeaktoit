SWIFT_FLAGS ?=

.DEFAULT_GOAL := run

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*##"}; {printf "%-12s %s\n", $$1, $$2}'

.PHONY: run
run: ## Build (if needed) and launch the app
	swift run $(SWIFT_FLAGS)

.PHONY: build
build: ## Build the app in debug configuration
	swift build $(SWIFT_FLAGS)

.PHONY: clean
clean: ## Remove build artifacts
	swift package clean

.PHONY: rebuild
rebuild: ## Clean and then build from scratch
	swift package clean
	swift build $(SWIFT_FLAGS)

.PHONY: test
test: ## Execute the test suite
	swift test $(SWIFT_FLAGS)
