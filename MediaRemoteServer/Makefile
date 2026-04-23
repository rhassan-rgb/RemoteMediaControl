# Makefile for MediaRemoteServer
#
# Builds a .app bundle without needing an Xcode project. Run:
#     make            # build ./build/MediaRemoteServer.app
#     make run        # build + launch (logs to stdout)
#     make install    # copy to /Applications
#     make autostart  # install a LaunchAgent so it starts at login
#     make clean
#
# Requires: Xcode Command Line Tools (clang, codesign_allocate).

APP_NAME     := MediaRemoteServer
BUNDLE_ID    := com.ragab.MediaRemoteServer
BUILD_DIR    := build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR    := $(APP_BUNDLE)/Contents/MacOS
RES_DIR      := $(APP_BUNDLE)/Contents/Resources
EXEC         := $(MACOS_DIR)/$(APP_NAME)

SRCS := \
    Sources/main.mm \
    Sources/AppDelegate.mm \
    Sources/SocketServer.mm \
    Sources/CommandHandler.mm \
    Sources/MediaRemote.mm \
    Sources/PlayerConfig.mm \
    Sources/VolumeControl.mm

OBJCXX      := clang++
SDK         := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH_FLAGS  := -arch arm64 -arch x86_64
CXX_STD     := -std=c++17
WARN        := -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable
OPT         := -O2
OBJC_FLAGS  := -fobjc-arc -fobjc-weak

# Debug tracing. Off by default (release). Opt in with `make DEBUG=1`.
# When on, SocketServer / CommandHandler / PlayerConfig emit NSLog
# entries for every connection, line, and reply — useful locally, but
# they end up in the LaunchAgent log file, so we don't want them on in
# installs by default.
DEBUG       ?= 0
ifeq ($(DEBUG),1)
TRACE_DEFS  := -DMR_TRACE=1
else
TRACE_DEFS  := -DMR_TRACE=0
endif

CXXFLAGS := $(CXX_STD) $(WARN) $(OPT) $(OBJC_FLAGS) $(TRACE_DEFS) \
            -isysroot $(SDK) $(ARCH_FLAGS) \
            -mmacosx-version-min=12.0 -ISources
LDFLAGS  := -isysroot $(SDK) $(ARCH_FLAGS) -mmacosx-version-min=12.0 \
            -framework Cocoa -framework CoreAudio -framework IOKit

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(EXEC) $(RES_DIR)/Info.plist
	@# "Info.plist" actually lives in Contents/, not Resources/, but we
	@# also place a copy in Resources/ for completeness.
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@# Ad-hoc code signature so macOS 11+ will run it without Gatekeeper
	@# complaining on the same machine that built it.
	@codesign --force --deep --sign - $(APP_BUNDLE) 2>/dev/null || true
	@echo "Built $(APP_BUNDLE)"

$(EXEC): $(SRCS) | $(MACOS_DIR)
	$(OBJCXX) $(CXXFLAGS) $(SRCS) $(LDFLAGS) -o $(EXEC)

$(RES_DIR)/Info.plist: Resources/Info.plist | $(RES_DIR)
	cp Resources/Info.plist $@

# NOTE: players.yaml used to be copied in here, but the player table is
# now compiled into the binary (see SECURITY_REVIEW.md Server M-2 and
# Sources/PlayerConfig.mm). No on-disk YAML resource to stage.

$(MACOS_DIR) $(RES_DIR):
	@mkdir -p $@

run: $(APP_BUNDLE)
	@echo "Launching (Ctrl-C to quit)…"
	$(EXEC)

install: $(APP_BUNDLE)
	@rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

# Install a per-user LaunchAgent that relaunches the server at login and keeps
# it alive if it crashes.
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist

# Log directory for the LaunchAgent. We use ~/Library/Logs (owned by and
# readable only by the user) rather than /tmp — /tmp is world-readable
# on macOS and is periodically swept, which would strand the log files
# (and leak them to any other local user). See SECURITY_REVIEW.md L-2.
LOG_DIR     := $(HOME)/Library/Logs

autostart: install
	@mkdir -p $(HOME)/Library/LaunchAgents
	@mkdir -p $(LOG_DIR)
	@printf '%s\n' \
'<?xml version="1.0" encoding="UTF-8"?>' \
'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
'<plist version="1.0"><dict>' \
'  <key>Label</key><string>$(BUNDLE_ID)</string>' \
'  <key>ProgramArguments</key><array>' \
'    <string>/Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)</string>' \
'  </array>' \
'  <key>RunAtLoad</key><true/>' \
'  <key>KeepAlive</key><true/>' \
'  <key>StandardOutPath</key><string>$(LOG_DIR)/$(APP_NAME).log</string>' \
'  <key>StandardErrorPath</key><string>$(LOG_DIR)/$(APP_NAME).err</string>' \
'</dict></plist>' > $(AGENT_PLIST)
	@launchctl unload $(AGENT_PLIST) 2>/dev/null || true
	@launchctl load   $(AGENT_PLIST)
	@echo "Autostart enabled ($(AGENT_PLIST))"
	@echo "Logs: $(LOG_DIR)/$(APP_NAME).log (and .err)"

unautostart:
	@launchctl unload $(AGENT_PLIST) 2>/dev/null || true
	@rm -f $(AGENT_PLIST)
	@echo "Autostart removed"

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run install autostart unautostart clean
