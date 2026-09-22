### DEBUG BUILD ###

debug: \
		build-debug/ExportHEIC.lrdevplugin \
		build-debug/hdr-image-tool

clean-debug:
	rm -rf ./build-debug ./.build

.build/debug/ConvertToHeic: \
		Package.swift \
		Package.resolved \
		$(wildcard ConvertToHeic/*) \
		$(wildcard HEIFEncoding/*)
	swift build --configuration debug --product ConvertToHeic
	@test -x $@
	@touch -c $@

.build/debug/hdr-image-tool: \
		Package.swift \
		Package.resolved \
		$(wildcard Tools/HDRImageTool/*.swift) \
		$(wildcard HEIFEncoding/*) \
		.build/debug/ConvertToHeic
	swift build --configuration debug --product hdr-image-tool
	@test -x $@
	@touch -c $@

build-debug/ConvertToHeic: .build/debug/ConvertToHeic
	mkdir -p $(@D)
	cd $(@D) && ln -s -f ../$< ./

build-debug/hdr-image-tool: .build/debug/hdr-image-tool
	mkdir -p $(@D)
	cd $(@D) && ln -s -f ../$< ./

build-debug/ExportHEIC.lrdevplugin: \
		$(wildcard LRPlugin/*) \
		build-debug/ConvertToHeic
	mkdir -p $@/ConverterWrapper.app/Contents/MacOS/
	cd $@ && for f in $(wildcard LRPlugin/*.lua); do ln -s -f ../../$$f; done
	scripts/update_version.sh LRPlugin/Info.lua.template > $@/Info.lua
	cd $@/ConverterWrapper.app/Contents/MacOS && ln -s -f ../../../../ConvertToHeic
	@touch -c $@


### RELEASE BUILD ###

clean-release:
	rm -rf ./build-release ./DerivedData

build-release/ConverterWrapper.xcarchive: \
		$(wildcard ConvertToHeic/*) \
		$(wildcard HEIFEncoding/*) \
		$(shell find ConverterWrapper -type f) \
		$(shell find ConverterWrapper.xcodeproj -type f -not -path '*/xcuserdata/*')
	@if test -z "$$TEAM_ID"; then  \
		echo 'Environment variable TEAM_ID must be set to perform code signing.';  \
		exit 1; \
	fi >&2
	xcodebuild -scheme ConverterWrapper \
		-destination "generic/platform=macOS,name=Any Mac" \
		-configuration Release \
		-derivedDataPath ./DerivedData \
		-archivePath ./$@ \
		archive "DEVELOPMENT_TEAM=$$TEAM_ID"
	@touch -c $@ $@/Products/Applications

# Link the parent directory to make `stapler` happy; it doesn't want a symlink.
build-release/Applications: build-release/ConverterWrapper.xcarchive
	mkdir -p $(@D)
	cd $(@D) && ln -s -f ConverterWrapper.xcarchive/Products/Applications
	@test -x $@/ConverterWrapper.app

release-build: build-release/Applications

#=== step 1 end: release-build ===

build-release/candidate.zip: build-release/Applications
	rm -f $@
	zip -r $@ $<

uuid_regex = '\b\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\b'
notarize_auth = --key "$$API_KEY_PATH" --key-id "$$API_KEY_ID" --issuer "$$API_KEY_ISSUER"
ifneq '${STORED_CRED}' ''
notarize_auth = --keychain-profile "$$STORED_CRED"
endif

build-release/notarize.log: \
		build-release/candidate.zip \
		build-release/Applications
	@if test -n "$$STORED_CRED" -o '(' -n "$$API_KEY_ID" -a -n "$$API_KEY_ISSUER" -a -n "$$API_KEY_PATH" ')'; then  \
		true;  \
	else  \
		echo 'One set of the following environment variables must be set to perform notarization:';  \
		echo '1) STORED_CRED';  \
		echo '2) API_KEY_ID, API_KEY_ISSUER and API_KEY_PATH';  \
		exit 1;  \
	fi >&2
	xcrun notarytool submit $< ${notarize_auth} --wait | tee $@.attempt
	@if ! egrep -q ${uuid_regex} $@.attempt; then  \
		exit 1;  \
	elif ! grep -q Accepted $@.attempt; then  \
		xcrun notarytool log ${notarize_auth} $$(  \
				egrep -o ${uuid_regex} $@.attempt | head -n 1 );  \
		exit 1;  \
	fi
	xcrun stapler staple build-release/Applications/ConverterWrapper.app
	@cat $@.attempt > $@

release-notarize: build-release/notarize.log

#=== step 2 end: release-notarize ===

build-release/ExportHEIC.lrplugin: \
		$(wildcard LRPlugin/*) \
		build-release/notarize.log \
		build-release/Applications
	mkdir -p $@
	cd $@ && for f in $(wildcard LRPlugin/*.lua); do ln -s -f ../../$$f; done
	scripts/update_version.sh LRPlugin/Info.lua.template > $@/Info.lua
	cd $@ && ln -s -f ../Applications/ConverterWrapper.app/
	@touch -c $@

build-release/ExportHEIC.lrplugin.zip: build-release/ExportHEIC.lrplugin
	rm -f $@
	cd $(@D) && zip -r ExportHEIC.lrplugin.zip ExportHEIC.lrplugin/

release: build-release/ExportHEIC.lrplugin.zip


### MISC

LUA_FILES := $(shell git ls-files --cached --others --exclude-standard \
	-- '*.lua' '*.lua.template' | sort)
SWIFT_FILES := $(shell git ls-files --cached --others --exclude-standard \
	-- '*.swift' | sort)
SHELL_FILES := $(shell git ls-files --cached --others --exclude-standard \
	-- '*.sh' | sort)

lint:
	stylua --check --verify $(LUA_FILES)
	luac -p $(LUA_FILES)
	swift format lint --strict $(SWIFT_FILES)
	bash -n $(SHELL_FILES)
	git diff --check

fmt:
	stylua --verify $(LUA_FILES)
	swift format format --in-place $(SWIFT_FILES)

test:
	swift test

clean: clean-debug clean-release

.PHONY: debug fmt lint test release release-build release-notarize \
	clean clean-debug clean-release
