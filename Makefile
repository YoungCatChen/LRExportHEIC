### DEBUG MAKE

debug: build-debug/ExportHEIC.lrdevplugin

clean-debug:
	rm -rf ./build-debug ./.build

build-debug/ExportHEIC.lrdevplugin: \
		$(wildcard LRPlugin/*) \
		build-debug/ConvertToHeic
	mkdir -p $@/ConverterWrapper.app/Contents/MacOS/
	cd $@ && for f in $(wildcard LRPlugin/*); do ln -s -f ../../$$f; done
	cd $@/ConverterWrapper.app/Contents/MacOS && ln -s -f ../../../../ConvertToHeic
	@touch -c $@

build-debug/ConvertToHeic: .build/apple/Products/Debug/ConvertToHeic
	mkdir -p $(@D)
	cd $(@D) && ln -s -f ../$< ./

.build/apple/Products/Debug/ConvertToHeic: $(wildcard ConvertToHeic/*)
	swift build --configuration debug --arch x86_64 --arch arm64
	@test -x $@
	@touch -c $@


### RELEASE MAKE

clean-release:
	rm -rf ./build-release ./DerivedData

build-release/ConverterWrapper.xcarchive: \
		$(wildcard ConvertToHeic/*) \
		$(shell find ConverterWrapper -type f) \
		$(shell find ConverterWrapper.xcodeproj -type f -not -path '*/xcuserdata/*')
	xcodebuild -scheme ConverterWrapper \
		-destination 'name=Any Mac' \
		-configuration Release \
		-derivedDataPath ./DerivedData \
		-archivePath ./$@ \
		archive DEVELOPMENT_TEAM=W5MWTSVZPB
	@touch -c $@ $@/Products/Applications

# Link the parent directory to make `stapler` happy; it doesn't want a symlink.
build-release/Applications: build-release/ConverterWrapper.xcarchive
	mkdir -p $(@D)
	cd $(@D) && ln -s -f ConverterWrapper.xcarchive/Products/Applications
	@test -x $@/ConverterWrapper.app

release-build: build-release/Applications

build-release/candidate.zip: build-release/Applications
	rm -f $@
	zip -r $@ $<

uuid_regex = '\b\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\b'

build-release/notarize.log: \
		build-release/candidate.zip \
		build-release/Applications
	xcrun notarytool submit $< --keychain-profile aaa --wait | tee $@.attempt
	@if ! egrep -q ${uuid_regex} $@.attempt; then  \
		exit 1;  \
	elif ! grep -q Accepted $@.attempt; then  \
		xcrun notarytool log --keychain-profile aaa $$(  \
				egrep -o ${uuid_regex} $@.attempt | head -n 1 );  \
		exit 1;  \
	fi
	xcrun stapler staple build-release/Applications/ConverterWrapper.app
	@cat $@.attempt > $@

release-notarize: build-release/notarize.log

build-release/ExportHEIC.lrplugin: \
		$(wildcard LRPlugin/*) \
		build-release/notarize.log \
		build-release/Applications
	mkdir -p $@
	cd $@ && for f in $(wildcard LRPlugin/*); do ln -s -f ../../$$f; done
	cd $@ && ln -s -f ../Applications/ConverterWrapper.app/
	@touch -c $@

build-release/ExportHEIC.lrplugin.zip: build-release/ExportHEIC.lrplugin
	rm -f $@
	cd $(@D) && zip -r ExportHEIC.lrplugin.zip ExportHEIC.lrplugin/

release-distribution: build-release/ExportHEIC.lrplugin.zip


### MISC

clean: clean-debug clean-release

.PHONY: debug release-build release-notarize release-distribution \
	clean clean-debug clean-release
