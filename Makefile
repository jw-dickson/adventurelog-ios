# AdventureLog for iOS — common tasks. Run `make help`.

SIM := scripts/simulator.sh
PROJECT := AdventureLog.xcodeproj
XCB_SIM = -project $(PROJECT) -scheme AdventureLog -destination "$$($(SIM) destination)" \
          -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO

.PHONY: help bootstrap generate tokens test test-packages test-ui gallery build run clean

help:
	@echo "make bootstrap      install XcodeGen if needed, generate tokens and the Xcode project"
	@echo "make generate       regenerate Tokens.swift and AdventureLog.xcodeproj"
	@echo "make test           package tests, then Simulator UI tests"
	@echo "make test-packages  Swift package tests on macOS (fast, no Simulator)"
	@echo "make test-ui        UI tests on the newest iPhone simulator (the gallery has its own target)"
	@echo "                    end to end: AL_TEST_SERVER=http://127.0.0.1:8000 AL_TEST_API_KEY=al_… make test-ui"
	@echo "make gallery        screenshots of every screen (light, dark, XXL) into build/gallery"
	@echo "make run            build, install and launch in the Simulator"

bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@$(MAKE) generate

tokens:
	python3 scripts/gen-tokens.py

generate: tokens
	xcodegen generate --quiet

test: test-packages test-ui

# CI passes SWIFT_FLAGS="-Xswiftc -warnings-as-errors"; locally a warning stays a warning.
SWIFT_FLAGS ?=

test-packages:
	cd Packages/AdventureLogKit && swift test $(SWIFT_FLAGS)
	cd Packages/ALStore && swift test $(SWIFT_FLAGS)
	cd Packages/ALDesign && swift test $(SWIFT_FLAGS)

test-ui: generate
	TEST_RUNNER_AL_TEST_SERVER="$(AL_TEST_SERVER)" TEST_RUNNER_AL_TEST_API_KEY="$(AL_TEST_API_KEY)" \
	  xcodebuild test $(XCB_SIM) -skip-testing:AdventureLogUITests/GalleryUITests \
	  -resultBundlePath build/UITests-$$(date +%Y%m%d-%H%M%S).xcresult

gallery: generate
	rm -rf build/Gallery.xcresult build/gallery
	xcodebuild test $(XCB_SIM) -only-testing:AdventureLogUITests/GalleryUITests -resultBundlePath build/Gallery.xcresult
	mkdir -p build/gallery
	xcrun xcresulttool export attachments --path build/Gallery.xcresult --output-path build/gallery
	@echo "Screenshots in build/gallery (manifest.json maps files to names)"

build: generate
	xcodebuild build $(XCB_SIM) -quiet

run: generate
	$(SIM) run

clean:
	rm -rf build $(PROJECT) App/Info.plist
	cd Packages/AdventureLogKit && swift package clean
	cd Packages/ALStore && swift package clean
	cd Packages/ALDesign && swift package clean
