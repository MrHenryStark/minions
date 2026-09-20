.PHONY: build test app dmg run install clean
build: ; swift build
test: ; swift test
app: ; scripts/bundle.sh release
dmg: app ; scripts/dmg.sh
run: app ; open build/Minions.app
install: app ; rm -rf /Applications/Minions.app && cp -R build/Minions.app /Applications/ && echo "installed /Applications/Minions.app"
clean: ; rm -rf .build build
