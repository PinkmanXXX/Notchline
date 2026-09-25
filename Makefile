APP     := Notchline
VERSION := 1.1
BUNDLE  := $(APP).app
BINDIR   = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BIN      = $(BINDIR)/$(APP)

.PHONY: all build bundle icon dmg run test e2e clean

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

## AppIcon.icns from the 1024 master, itself rendered from the SVG
icon: Resources/AppIcon.icns
AppIcon/AppIcon-1024.png: AppIcon/AppIcon.svg scripts/render-icon.swift
	swift scripts/render-icon.swift $< $@
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

## unit tests
test:
	swift test --skip NotchlineE2ETests

## end to end: the debug app, real zsh sessions and `notch`, in a throwaway home
e2e:
	swift build
	swift test --filter NotchlineE2ETests

clean:
	rm -rf .build $(BUNDLE) dmg $(APP).dmg Resources/AppIcon.icns
