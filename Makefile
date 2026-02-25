SWIFT_FLAGS ?=
ARCHIVE_PATH ?= ~/Desktop/JustSpeakToIt.xcarchive
EXPORT_PATH ?= ~/Desktop/JustSpeakToIt-AppStore

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

.PHONY: test-release
test-release: ## Run tests in release configuration
	swift test -c release $(SWIFT_FLAGS)

.PHONY: test-all
test-all: test test-release ## Run tests in both debug and release

.PHONY: release
release: ## Build optimized release binary
	swift build -c release $(SWIFT_FLAGS)

.PHONY: verify
verify: release ## Build release binary and verify it launches
	chmod +x scripts/verify-launch.sh
	./scripts/verify-launch.sh .build/release/SpeakApp

.PHONY: install-verify
install-verify: release ## Build release, install to /Applications, launch and verify
	@echo "Installing to /Applications/JustSpeakToIt-Dev.app..."
	rm -rf /Applications/JustSpeakToIt-Dev.app
	mkdir -p /Applications/JustSpeakToIt-Dev.app/Contents/MacOS
	cp .build/release/SpeakApp /Applications/JustSpeakToIt-Dev.app/Contents/MacOS/JustSpeakToIt
	cp -r .build/release/SpeakApp.app/Contents/Info.plist /Applications/JustSpeakToIt-Dev.app/Contents/ 2>/dev/null || true
	chmod +x scripts/verify-launch.sh
	./scripts/verify-launch.sh /Applications/JustSpeakToIt-Dev.app
	@echo "✅ Install verification passed"

.PHONY: preflight
preflight: test-all verify ## Full pre-release check (tests + launch verification)

.PHONY: install-hooks
install-hooks: ## Install git hooks for pre-push verification
	git config core.hooksPath .githooks
	@echo "✓ Git hooks installed (pre-push → make preflight)"

.PHONY: xcode
xcode: ## Generate and open Xcode workspace
	tuist generate
	open "Just Speak to It.xcworkspace"

.PHONY: archive
archive: ## Create Xcode archive for App Store
	@echo "Creating archive at $(ARCHIVE_PATH)..."
	xcodebuild -workspace "Just Speak to It.xcworkspace" \
		-scheme "SpeakApp" \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		archive
	@echo "Archive created at $(ARCHIVE_PATH)"

.PHONY: export-appstore
export-appstore: ## Export archive for App Store submission
	@echo "Exporting for App Store..."
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist Config/ExportOptions-AppStore.plist \
		-exportPath $(EXPORT_PATH)
	@echo "Exported to $(EXPORT_PATH)"

.PHONY: version
version: ## Display current version
	@cat VERSION
