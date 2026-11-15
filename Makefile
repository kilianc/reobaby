APP := build/ReoBaby.app
# `make release` builds for both Apple silicon and Intel.
ARCHS ?=
SWIFT_FLAGS = -c release $(addprefix --arch ,$(ARCHS))
BIN_DIR = $(shell swift build $(SWIFT_FLAGS) --show-bin-path)
# The app's binary is ReoBabyApp until it goes in the bundle: on a case-insensitive disk,
# ReoBaby and the CLI's reobaby would be the same file.
BIN = $(BIN_DIR)/ReoBabyApp
CLI = $(BIN_DIR)/reobaby
# Where `make link` puts the reobaby command.
BINDIR ?= /usr/local/bin
# A real signing identity keeps "Always Allow" keychain grants across rebuilds;
# ad-hoc signing ("-") makes every build a new app to the keychain.
SIGN_ID ?= $(or $(shell security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $$2; exit}'),-)

.PHONY: build app run install link release probe discover linux hero test-server test-server-stop clean

build:
	swift build $(SWIFT_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Helpers
	cp $(BIN) $(APP)/Contents/MacOS/ReoBaby
	cp $(CLI) $(APP)/Contents/Helpers/reobaby
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	[ ! -f Resources/AppIcon.icns ] || cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	# The CLI first: the app's signature covers it. It carries the app's Info.plist, so it signs
	# as the app and reads the keychain passwords the app saved without asking.
	codesign --force --sign "$(SIGN_ID)" $(APP)/Contents/Helpers/reobaby
	codesign --force --sign "$(SIGN_ID)" $(APP)

run: app
	open $(APP)

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/ReoBaby.app
	cp -R $(APP) ~/Applications/ReoBaby.app

# The reobaby command on your PATH, from the installed app, so app updates update it too.
link:
	ln -sf ~/Applications/ReoBaby.app/Contents/Helpers/reobaby $(BINDIR)/reobaby

# Universal app, zipped for a GitHub release: build/ReoBaby.zip
release: ARCHS = arm64 x86_64
release: app
	@[ "$(SIGN_ID)" != "-" ] || { echo "make release needs your signing certificate: ReoBaby only installs updates signed like the copy they replace."; exit 1; }
	rm -f build/ReoBaby.zip
	ditto -c -k --keepParent $(APP) build/ReoBaby.zip
	@echo "build/ReoBaby.zip: app $$(lipo -archs $(APP)/Contents/MacOS/ReoBaby), reobaby $$(lipo -archs $(APP)/Contents/Helpers/reobaby)"

# reobaby for Linux, built in Swift's own Docker image with the Swift runtime linked in:
# build/linux/reobaby-linux-arm64 and -x86_64 run on any glibc 2.35+ Linux (Ubuntu 22.04,
# Debian 12, Raspberry Pi OS 12) with no Swift installed. x86_64 builds under emulation: slow.
SWIFT_IMAGE ?= swift:6.4.2-jammy
LINUX_ARCHS ?= arm64 x86_64
linux:
	mkdir -p build/linux
	for arch in $(LINUX_ARCHS); do \
	  platform=$$([ $$arch = x86_64 ] && echo amd64 || echo $$arch); \
	  docker run --rm --platform linux/$$platform -u "$$(id -u):$$(id -g)" -e HOME=/tmp -v "$(CURDIR):/work" -w /work \
	    $(SWIFT_IMAGE) sh -c "swift build -c release --static-swift-stdlib -Xlinker -s --scratch-path .build/linux-$$arch --product reobaby \
	      && cp \$$(swift build -c release --static-swift-stdlib -Xlinker -s --scratch-path .build/linux-$$arch --show-bin-path)/reobaby build/linux/reobaby-linux-$$arch" \
	    || exit 1; \
	done
	@ls -l build/linux

# Reolink cameras on the local network, as Settings ▸ Cameras finds them.
discover: app
	$(APP)/Contents/Helpers/reobaby discover

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
	$(APP)/Contents/Helpers/reobaby probe "$(CAM)" $(or $(SECONDS),8)

# Local RTSP test server: rtsp://tester:testpass@127.0.0.1:8554/{nursery,h264,h265,beeps}
test-server:
	docker run -d --rm --name reobaby-test-rtsp -p 127.0.0.1:8554:8554 \
		-v "$(CURDIR)/test/mediamtx.yml:/mediamtx.yml:ro" -v "$(CURDIR)/test/demo:/demo:ro" bluenviron/mediamtx:1.9.3-ffmpeg

test-server-stop:
	docker stop reobaby-test-rtsp

clean:
	rm -rf .build build
