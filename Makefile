.PHONY: gen test build run

gen:
	xcodegen generate

test: gen
	xcodebuild -project Minutia.xcodeproj -scheme Minutia -destination 'platform=macOS' -derivedDataPath build test CODE_SIGNING_ALLOWED=NO

build: gen
	xcodebuild -project Minutia.xcodeproj -scheme Minutia -destination 'platform=macOS' -derivedDataPath build build CODE_SIGNING_ALLOWED=NO

run: build
	open build/Build/Products/Debug/Minutia.app

