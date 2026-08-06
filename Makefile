SWIFT_FLAGS ?=
ARCHIVE_PATH ?= ~/Desktop/JustSpeakToIt.xcarchive
EXPORT_PATH ?= ~/Desktop/JustSpeakToIt-AppStore
# Provisioning profile used for Mac App Store manual signing. Project.swift only applies
# manual signing when TUIST_MAC_PROFILE_NAME is set — Tuist forwards only TUIST_-prefixed
# variables into manifest evaluation, so a plain MAC_PROFILE_NAME in the shell would be
# dropped. Accept either spelling here and forward it explicitly.
MAC_PROFILE_NAME ?=
TUIST_MAC_PROFILE_NAME ?= $(MAC_PROFILE_NAME)

.DEFAULT_GOAL := run

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*##"}; {printf "%-12s %s\n", $$1, $$2}'

.PHONY: run
run: ## Build (if needed) and launch the app
	swift run $(SWIFT_FLAGS) SpeakApp

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

.PHONY: lint
lint: ## Run strict SwiftLint against the checked-in debt baseline
	swift package plugin --allow-writing-to-package-directory swiftlint --strict --baseline .swiftlint-baseline.json

.PHONY: format
format: ## Auto-fix formatting and lint violations where possible
	swift package plugin --allow-writing-to-package-directory swiftformat --recursive
	swift package plugin --allow-writing-to-package-directory swiftlint --fix --format

.PHONY: verify-checksums
verify-checksums: ## Verify binary XCFramework and package checksums
	./scripts/verify-checksums.sh

.PHONY: install-hooks
install-hooks: ## Install git hooks for pre-push verification
	git config core.hooksPath .githooks
	@echo "✓ Git hooks installed (pre-push → make preflight)"

.PHONY: xcode
xcode: ## Generate and open Xcode workspace
	tuist generate
	open "Just Speak to It.xcworkspace"

.PHONY: archive
archive: ## Create Xcode archive of the direct/Developer ID flavour
	@echo "Generating direct flavour (TUIST_APP_STORE=0)..."
	TUIST_APP_STORE=0 tuist generate --no-open
	@echo "Creating archive at $(ARCHIVE_PATH)..."
	xcodebuild -workspace "Just Speak to It.xcworkspace" \
		-scheme "SpeakApp" \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		archive
	@echo "Archive created at $(ARCHIVE_PATH)"

.PHONY: archive-appstore
archive-appstore: ## Regenerate the App Store flavour and create its Xcode archive
	@echo "Generating App Store flavour (TUIST_APP_STORE=1)..."
	@if [ -z "$(TUIST_MAC_PROFILE_NAME)" ]; then \
		echo "⚠️  No MAC_PROFILE_NAME set: generating with automatic signing."; \
		echo "   For a distributable archive run: make archive-appstore MAC_PROFILE_NAME=\"<profile name>\""; \
	fi
	TUIST_APP_STORE=1 TUIST_MAC_PROFILE_NAME="$(TUIST_MAC_PROFILE_NAME)" tuist generate --no-open
	@echo "Creating archive at $(ARCHIVE_PATH)..."
	xcodebuild -workspace "Just Speak to It.xcworkspace" \
		-scheme "SpeakApp" \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		archive
	@echo "Archive created at $(ARCHIVE_PATH)"

.PHONY: export-appstore
export-appstore: archive-appstore ## Archive the App Store flavour and export it for submission
	@echo "Exporting for App Store..."
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist Config/ExportOptions-AppStore.plist \
		-exportPath $(EXPORT_PATH)
	@echo "Exported to $(EXPORT_PATH)"

.PHONY: version
version: ## Display current version
	@cat VERSION
