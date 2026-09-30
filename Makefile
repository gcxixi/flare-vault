CC = clang
CFLAGS = -Wall -Wextra -O2 -fobjc-arc -mmacosx-version-min=12.0
FRAMEWORKS = -framework Cocoa -framework Security

APP_NAME = FlareVault
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

CORE_SRCS = FlareVault/Core/FVCryptoEngine.m \
            FlareVault/Core/FVKeyManager.m \
            FlareVault/Core/FVArchiver.m \
            FlareVault/Core/FVSnapshotManager.m \
            FlareVault/Core/FVCloudflareUploader.m \
            FlareVault/Core/FVConfigManager.m \
            FlareVault/Core/FVTaskPipeline.m

UI_SRCS = FlareVault/UI/FVDragDropView.m \
          FlareVault/UI/FVMainWindowController.m

MAIN_SRCS = FlareVault/Main/FVAppDelegate.m \
            FlareVault/Main/main.m

ALL_SRCS = $(CORE_SRCS) $(UI_SRCS) $(MAIN_SRCS)

.PHONY: all app cli test clean run

all: app cli

app: $(APP_BUNDLE)

$(APP_BUNDLE): $(ALL_SRCS) FlareVault/Resources/Info.plist FlareVault/Resources/AppIcon.icns
	@mkdir -p $(MACOS) $(RESOURCES)
	@echo "==> Compiling $(APP_NAME) executable..."
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(ALL_SRCS) -o $(MACOS)/$(APP_NAME)
	@cp FlareVault/Resources/Info.plist $(CONTENTS)/Info.plist
	@cp FlareVault/Resources/AppIcon.icns $(RESOURCES)/AppIcon.icns
	@echo "==> Created Application Bundle: $(APP_BUNDLE)"

cli: $(BUILD_DIR)/flare-vault-decrypt

$(BUILD_DIR)/flare-vault-decrypt: Tools/flare-vault-decrypt.m FlareVault/Core/FVCryptoEngine.m FlareVault/Core/FVArchiver.m
	@mkdir -p $(BUILD_DIR)
	@echo "==> Compiling decryption CLI tool..."
	$(CC) $(CFLAGS) $(FRAMEWORKS) $^ -o $@
	@echo "==> Compiled CLI: $@"

test:
	@echo "==> Running Crypto Tests..."
	@clang $(CFLAGS) $(FRAMEWORKS) FlareVault/Core/FVCryptoEngine.m Tests/test_crypto.m -o $(BUILD_DIR)/test_crypto && $(BUILD_DIR)/test_crypto
	@echo "==> Running KeyManager Tests..."
	@clang $(CFLAGS) $(FRAMEWORKS) FlareVault/Core/FVCryptoEngine.m FlareVault/Core/FVKeyManager.m Tests/test_keymanager.m -o $(BUILD_DIR)/test_keymanager && $(BUILD_DIR)/test_keymanager
	@echo "==> Running Archiver Tests..."
	@clang $(CFLAGS) $(FRAMEWORKS) FlareVault/Core/FVArchiver.m Tests/test_archiver.m -o $(BUILD_DIR)/test_archiver && $(BUILD_DIR)/test_archiver
	@echo "==> Running Snapshot Differential Tests..."
	@clang $(CFLAGS) $(FRAMEWORKS) FlareVault/Core/FVArchiver.m FlareVault/Core/FVSnapshotManager.m Tests/test_snapshot.m -o $(BUILD_DIR)/test_snapshot && $(BUILD_DIR)/test_snapshot
	@echo "==> Running Uploader Tests..."
	@clang $(CFLAGS) $(FRAMEWORKS) FlareVault/Core/FVCloudflareUploader.m Tests/test_uploader.m -o $(BUILD_DIR)/test_uploader && $(BUILD_DIR)/test_uploader
	@echo "==> Running Lazy Upload Stochastic Math Tests..."
	@clang $(CFLAGS) $(FRAMEWORKS) FlareVault/Core/FVCloudflareUploader.m Tests/test_lazy_upload.m -o $(BUILD_DIR)/test_lazy_upload && $(BUILD_DIR)/test_lazy_upload
	@echo "==> Running End-to-End Test Suite..."
	@bash Scripts/test_e2e.sh
	@echo "==> ALL TESTS PASSED SUCCESSFULLY!"

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR) Tests/test_crypto Tests/test_keymanager Tests/test_archiver
