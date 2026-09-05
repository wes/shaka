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
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@cp -r $(BUNDLE) /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"
	@echo ""
	@echo "⚠️  Re-grant Accessibility permission."
	@echo "   Shaka is ad-hoc signed, so replacing the binary invalidates the"
	@echo "   existing grant. macOS keeps showing Shaka as ticked but denies it,"
	@echo "   and every shortcut silently stops working."
	@echo ""
	@echo "   System Settings > Privacy & Security > Accessibility"
	@echo "   Remove Shaka with the minus button, then add it back."
	@echo ""
	@echo "   Or reset it from the terminal, then relaunch Shaka:"
	@echo "     tccutil reset Accessibility com.wes.shaka"
	@echo ""
	@echo "Open Shaka from Spotlight or /Applications."

uninstall:
	@rm -rf /Applications/$(BUNDLE)
	@echo "Uninstalled Shaka from /Applications"

clean:
	swift package clean
	@rm -rf $(BUNDLE)
