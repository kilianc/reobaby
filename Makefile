APP := build/ReoBaby.app
# `make release` builds for both Apple silicon and Intel.
ARCHS ?=
SWIFT_FLAGS = -c release $(addprefix --arch ,$(ARCHS))
BIN = $(shell swift build $(SWIFT_FLAGS) --show-bin-path)/ReoBaby
# A real signing identity keeps "Always Allow" keychain grants across rebuilds;
# ad-hoc signing ("-") makes every build a new app to the keychain.
SIGN_ID ?= $(or $(shell security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $$2; exit}'),-)

.PHONY: build app run install release probe discover hero test-server test-server-stop clean

build:
	swift build $(SWIFT_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/ReoBaby
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	[ ! -f Resources/AppIcon.icns ] || cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force --sign "$(SIGN_ID)" $(APP)

run: app
	open $(APP)

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/ReoBaby.app
	cp -R $(APP) ~/Applications/ReoBaby.app

# Universal app, zipped for a GitHub release: build/ReoBaby.zip
release: ARCHS = arm64 x86_64
release: app
	@[ "$(SIGN_ID)" != "-" ] || { echo "make release needs your signing certificate: ReoBaby only installs updates signed like the copy they replace."; exit 1; }
	rm -f build/ReoBaby.zip
	ditto -c -k --keepParent $(APP) build/ReoBaby.zip
	@echo "build/ReoBaby.zip: $$(lipo -archs $(APP)/Contents/MacOS/ReoBaby)"

# Reolink cameras on the local network, as the Cameras window finds them.
discover: app
	$(APP)/Contents/MacOS/ReoBaby --discover

# docs/hero.jpg, the README and link-preview picture: headless Chrome screenshots the site's
# simulated desktop (docs/index.html#shot) at 2x, and sips scales it to 1600 px wide.
CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
hero:
	mkdir -p build
	"$(CHROME)" --headless=new --user-data-dir=build/.chrome --hide-scrollbars --window-size=1440,900 \
	  --force-device-scale-factor=2 --virtual-time-budget=3000 --screenshot=build/hero.png "file://$(CURDIR)/docs/index.html#shot"
	sips -Z 1600 -s format jpeg -s formatOptions 86 build/hero.png --out docs/hero.jpg

# make probe CAM="Front Door"   (name, 1-based number, or rtsp:// URL)
probe: app
	$(APP)/Contents/MacOS/ReoBaby --probe "$(CAM)" $(or $(SECONDS),8)

# Local RTSP test server: rtsp://tester:testpass@127.0.0.1:8554/{nursery,h264,h265,beeps}
test-server:
	docker run -d --rm --name reobaby-test-rtsp -p 127.0.0.1:8554:8554 \
		-v "$(CURDIR)/test/mediamtx.yml:/mediamtx.yml:ro" -v "$(CURDIR)/test/demo:/demo:ro" bluenviron/mediamtx:1.9.3-ffmpeg

test-server-stop:
	docker stop reobaby-test-rtsp

clean:
	rm -rf .build build
