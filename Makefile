.PHONY: gen test build run archive export dmg notarize release

APP_NAME    := Minutia
BUILD_DIR   := build
ARCHIVE     := $(BUILD_DIR)/$(APP_NAME).xcarchive
EXPORT_DIR  := $(BUILD_DIR)/export
EXPORT_APP  := $(EXPORT_DIR)/$(APP_NAME).app
DEBUG_APP   := $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app
VERSION     := $(shell grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
DMG         := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

gen:
	xcodegen generate

test: gen
	xcodebuild -project Minutia.xcodeproj -scheme Minutia -destination 'platform=macOS' -derivedDataPath build test CODE_SIGNING_ALLOWED=NO

build: gen
	xcodebuild -project Minutia.xcodeproj -scheme Minutia -destination 'platform=macOS' -derivedDataPath build build CODE_SIGNING_ALLOWED=NO

run: build
	open $(DEBUG_APP)

# Developer ID archive. Requires a Developer ID Application identity in the keychain and a team
# id in DEVELOPMENT_TEAM; the release workflow supplies both. MARKETING_VERSION / CURRENT_PROJECT_VERSION
# can be overridden on the command line to stamp the build from a git tag.
archive: gen
	xcodebuild -project Minutia.xcodeproj -scheme Minutia -configuration Release \
		-derivedDataPath $(BUILD_DIR) -archivePath $(ARCHIVE) archive

export:
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist scripts/ExportOptions.plist -exportPath $(EXPORT_DIR)

# Assemble a DMG with an Applications drop link. Prefers the signed/exported app; falls back to a
# local unsigned Debug build so `make dmg` yields a runnable DMG on any machine without a Developer
# ID cert. create-dmg can exit non-zero while still producing the image on headless hosts, so the
# result is confirmed by existence rather than exit code.
dmg:
	@set -e; \
	if [ -d "$(EXPORT_APP)" ]; then APP="$(EXPORT_APP)"; \
	else echo "No exported app; building an unsigned local app for the DMG"; $(MAKE) build; APP="$(DEBUG_APP)"; fi; \
	STAGE="$(BUILD_DIR)/dmg-stage"; \
	rm -rf "$$STAGE" "$(DMG)"; mkdir -p "$$STAGE"; \
	cp -R "$$APP" "$$STAGE/"; \
	create-dmg \
		--volname "$(APP_NAME)" \
		--window-size 600 400 \
		--icon "$(APP_NAME).app" 150 190 \
		--app-drop-link 450 190 \
		"$(DMG)" "$$STAGE" || true; \
	rm -rf "$$STAGE"; \
	test -f "$(DMG)" && echo "Built $(DMG)"

# Notarize the exported app and staple the ticket. Guarded on the App Store Connect API key env:
# ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH (path to the .p8). The release workflow runs the
# equivalent steps inline against the DMG's app.
notarize:
	@if [ -z "$$ASC_KEY_ID" ] || [ -z "$$ASC_ISSUER_ID" ] || [ -z "$$ASC_KEY_PATH" ]; then \
		echo "notarize: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set"; exit 1; fi
	ditto -c -k --keepParent "$(EXPORT_APP)" "$(BUILD_DIR)/$(APP_NAME).zip"
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).zip" --wait \
		--key "$$ASC_KEY_PATH" --key-id "$$ASC_KEY_ID" --issuer "$$ASC_ISSUER_ID"
	xcrun stapler staple "$(EXPORT_APP)"

# Full local documentation of the release chain. CI (.github/workflows/release.yml) runs the real,
# credentialed pipeline on a v* tag; this target just names the ordered steps for a manual run.
release:
	@echo "Release chain (run by .github/workflows/release.yml on a v* tag):"
	@echo "  1. make archive            # Developer ID signed archive"
	@echo "  2. make export             # export .app via scripts/ExportOptions.plist"
	@echo "  3. sign nested Sparkle helpers, then Sparkle.framework, then Minutia.app (never --deep)"
	@echo "  4. make notarize           # notarytool submit --wait + stapler staple"
	@echo "  5. make dmg                # package the stapled app into $(DMG)"
	@echo "  6. sign_update + appcast.xml, then upload the DMG and appcast to the GitHub Release"
