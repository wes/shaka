.PHONY: build run bundle install uninstall clean

APP_NAME = Shaka
BUNDLE   = $(APP_NAME).app

build:
	swift build -c release

run:
	swift run

bundle: build
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@cp .build/release/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	@cp Info.plist $(BUNDLE)/Contents/
	@echo "Built $(BUNDLE)"

install: bundle
	@cp -r $(BUNDLE) /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"
	@echo "Open Shaka from Spotlight or /Applications."

uninstall:
	@rm -rf /Applications/$(BUNDLE)
	@echo "Uninstalled Shaka from /Applications"

clean:
	swift package clean
	@rm -rf $(BUNDLE)
