SHELL := /bin/bash

APP_NAME := DriveStream
SCHEME := DriveStream
PROJECT := DriveStream.xcodeproj
BUILD_DIR := build
DIST_DIR := dist
APP := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app

.PHONY: all generate build universal debug run icons lint strict verify smoke integration services lifecycle sanitize security pin recovery native-test issue-tests review-tests test clean verify-arch

XCODEGEN ?= xcodegen

all: build

generate: project.yml
	"$(XCODEGEN)" generate --spec project.yml

build: generate
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-destination "generic/platform=macOS" \
		-derivedDataPath "$(BUILD_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGNING_ALLOWED=YES \
		ENABLE_HARDENED_RUNTIME=YES \
		build

universal: generate
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-destination "generic/platform=macOS" \
		-derivedDataPath "$(BUILD_DIR)" \
		ARCHS="arm64 x86_64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGNING_ALLOWED=YES \
		ENABLE_HARDENED_RUNTIME=YES \
		build
	@$(MAKE) verify-arch

verify-arch:
	@echo "Mach-O architectures:"
	@lipo -archs "$(APP)/Contents/MacOS/$(APP_NAME)"
	@lipo -archs "$(APP)/Contents/MacOS/$(APP_NAME)" | grep -q arm64
	@lipo -archs "$(APP)/Contents/MacOS/$(APP_NAME)" | grep -q x86_64
	@echo "Universal 2 verification passed (Apple Silicon + Intel)."

debug: generate
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "generic/platform=macOS" \
		-derivedDataPath "$(BUILD_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		build

run: build
	open "$(APP)"

icons:
	python3 Scripts/generate-icons.py

lint:
	plutil -lint Sources/Info.plist Sources/DriveStream.entitlements
	bash ./Scripts/verify-required-files.sh
	XCODEGEN="$(XCODEGEN)" bash ./Scripts/validate-project.sh
	bash ./Scripts/check-swift.sh parse
	@echo "Validation passed."

strict:
	bash ./Scripts/check-swift.sh typecheck

verify:
	bash ./Scripts/verify-required-files.sh

smoke:
	bash ./Scripts/run-model-tests.sh

integration:
	bash ./Scripts/run-rc-integration-tests.sh

services:
	bash ./Scripts/run-service-tests.sh

lifecycle:
	bash ./Scripts/run-lifecycle-tests.sh

sanitize:
	RC_TEST_TSAN=1 bash ./Scripts/run-rc-integration-tests.sh

security:
	bash ./Scripts/run-security-tests.sh

pin:
	bash ./Scripts/run-pin-tests.sh

native-test: generate
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination "platform=macOS" -derivedDataPath "$(BUILD_DIR)" CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" test

recovery:
	bash ./Scripts/run-recovery-tests.sh

issue-tests:
	bash ./Scripts/run-upload-safety-tests.sh
	bash ./Scripts/run-monitor-keychain-tests.sh
	bash ./Scripts/run-telemetry-tests.sh

review-tests:
	bash ./Scripts/run-review-regressions.sh

test: smoke integration services lifecycle security pin recovery issue-tests review-tests

clean:
	@python3 -c 'from pathlib import Path; import shutil; root=Path.cwd().resolve(); names=["$(BUILD_DIR)", "$(DIST_DIR)", "$(PROJECT)"]; targets=[root/name for name in names]; assert all(p.parent == root and p.name in ("build", "dist", "DriveStream.xcodeproj") and not p.is_symlink() for p in targets), "Refusing unsafe clean target"; [shutil.rmtree(p) for p in targets if p.is_dir()]'
