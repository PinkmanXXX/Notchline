APP     := NotchTape
VERSION := 0.4.0
BUNDLE  := $(APP).app
BINDIR   = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BIN      = $(BINDIR)/$(APP)

.PHONY: all build bundle icon dmg run test clean

all: dmg

## universal binary — one build, both architectures
build:
	swift build -c release --arch arm64 --arch x86_64

## assemble the .app by hand: no .xcodeproj to keep in the repo
bundle: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp "$(BIN)" $(BUNDLE)/Contents/MacOS/$(APP)
	cp "$(BINDIR)/notch" $(BUNDLE)/Contents/MacOS/notch
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@lipo -archs $(BUNDLE)/Contents/MacOS/$(APP)
	@lipo -archs $(BUNDLE)/Contents/MacOS/notch
	@echo "built $(BUNDLE)"

## AppIcon.icns from the 1024 master
icon: Resources/AppIcon.icns
Resources/AppIcon.icns: AppIcon/AppIcon-1024.png
	rm -rf /tmp/$(APP).iconset && mkdir -p /tmp/$(APP).iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $< --out /tmp/$(APP).iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) $< --out /tmp/$(APP).iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/$(APP).iconset -o $@

dmg: bundle
	rm -rf dmg $(APP).dmg
	mkdir -p dmg && cp -R $(BUNDLE) dmg/ && ln -s /Applications dmg/Applications
	hdiutil create -volname "$(APP)" -srcfolder dmg -ov -format UDZO $(APP).dmg
	@echo "built $(APP).dmg"

run: bundle
	open $(BUNDLE)

test:
	swift test

clean:
	rm -rf .build $(BUNDLE) dmg $(APP).dmg Resources/AppIcon.icns
