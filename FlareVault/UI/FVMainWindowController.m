//
//  FVMainWindowController.m
//  FlareVault
//

#import "FVMainWindowController.h"
#import "FVDragDropView.h"
#import "../Core/FVArchiver.h"
#import "../Core/FVCryptoEngine.h"
#import "../Core/FVKeyManager.h"
#import "../Core/FVConfigManager.h"
#import "../Core/FVCloudflareUploader.h"
#import "../Core/FVTaskPipeline.h"

@interface FVMainWindowController () <FVDragDropViewDelegate, NSTabViewDelegate>

// Directory UI
@property (nonatomic, strong) NSTextField *dirPathField;
@property (nonatomic, strong) NSButton *browseDirButton;
@property (nonatomic, strong) NSTextField *dirStatsLabel;
@property (nonatomic, strong) FVDragDropView *dragDropView;

// Key UI
@property (nonatomic, strong) NSTabView *keyTabView;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSButton *genKeypairButton;
@property (nonatomic, strong) NSTextField *keychainServiceField;
@property (nonatomic, strong) NSButton *loadKeychainButton;
@property (nonatomic, strong) NSButton *saveKeychainButton;
@property (nonatomic, strong) NSTextView *pemTextView;
@property (nonatomic, strong) NSButton *browsePemButton;
@property (nonatomic, strong) NSTextField *keyStatusLabel;

// Cloudflare UI
@property (nonatomic, strong) NSTextField *cfAccountIdField;
@property (nonatomic, strong) NSTextField *cfBucketField;
@property (nonatomic, strong) NSTextField *cfAccessKeyField;
@property (nonatomic, strong) NSSecureTextField *cfSecretKeyField;
@property (nonatomic, strong) NSTextField *cfPrefixField;
@property (nonatomic, strong) NSButton *testConnectionButton;
@property (nonatomic, strong) NSButton *rememberCredsCheckbox;

// Lazy Upload UI
@property (nonatomic, strong) NSButton *lazyUploadCheckbox;
@property (nonatomic, strong) NSPopUpButton *lazyPresetPopup;
@property (nonatomic, strong) NSTextField *lazyMinIntervalField;
@property (nonatomic, strong) NSTextField *lazyMaxIntervalField;
@property (nonatomic, strong) NSButton *lazyChunkJitterCheckbox;
@property (nonatomic, strong) NSTextField *lazyTipLabel;

// Action & Progress UI
@property (nonatomic, strong) NSButton *actionButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *progressLabel;
@property (nonatomic, strong) NSTextView *logTextView;

@property (nonatomic, strong, nullable) FVTaskPipeline *currentPipeline;

@end

@implementation FVMainWindowController

+ (instancetype)sharedController {
    static FVMainWindowController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FVMainWindowController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    NSRect frame = NSMakeRect(120, 100, 940, 780);
    NSWindowStyleMask style = NSWindowStyleMaskTitled |
                              NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:style
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = @"FlareVault - macOS 目录非对称加密与 Cloudflare 上传";
    win.minSize = NSMakeSize(880, 720);

    self = [super initWithWindow:win];
    if (self) {
        [self setupUI];
        [self loadSavedConfiguration];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;

    // Outer ScrollView to allow scrolling on smaller screens
    NSScrollView *outerScrollView = [[NSScrollView alloc] initWithFrame:contentView.bounds];
    outerScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    outerScrollView.hasVerticalScroller = YES;
    outerScrollView.hasHorizontalScroller = NO;
    outerScrollView.borderType = NSNoBorder;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 940, 1080)];
    outerScrollView.documentView = container;
    [contentView addSubview:outerScrollView];

    CGFloat curY = 1050;

    // --- Header Banner ---
    NSTextField *titleLabel = [self labelWithText:@"FlareVault" fontSize:22 bold:YES];
    titleLabel.frame = NSMakeRect(30, curY - 30, 200, 30);
    [container addSubview:titleLabel];

    NSTextField *subtitleLabel = [self labelWithText:@"目录非对称加密归档 (AppKit 原生实现 | 仅公钥加密无私钥 | 传输至 Cloudflare R2)"
                                            fontSize:12 bold:NO];
    subtitleLabel.textColor = [NSColor secondaryLabelColor];
    subtitleLabel.frame = NSMakeRect(240, curY - 26, 650, 22);
    [container addSubview:subtitleLabel];

    curY -= 40;
    NSBox *sep1 = [self separatorWithY:curY inContainer:container];
    (void)sep1;
    curY -= 15;

    // --- SECTION 1: Source Directory ---
    NSTextField *sec1Title = [self labelWithText:@"1. 选择要打包加密的本地目录" fontSize:14 bold:YES];
    sec1Title.frame = NSMakeRect(30, curY - 20, 400, 20);
    [container addSubview:sec1Title];

    curY -= 32;
    self.dirPathField = [[NSTextField alloc] initWithFrame:NSMakeRect(30, curY, 740, 26)];
    self.dirPathField.placeholderString = @"例如: /Users/sundust/Documents/MyProject";
    self.dirPathField.target = self;
    self.dirPathField.action = @selector(dirPathChanged:);
    [container addSubview:self.dirPathField];

    self.browseDirButton = [NSButton buttonWithTitle:@"浏览..." target:self action:@selector(browseDirectoryClicked:)];
    self.browseDirButton.frame = NSMakeRect(780, curY - 1, 120, 28);
    self.browseDirButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:self.browseDirButton];

    curY -= 24;
    self.dirStatsLabel = [self labelWithText:@"未选择目录" fontSize:11 bold:NO];
    self.dirStatsLabel.textColor = [NSColor secondaryLabelColor];
    self.dirStatsLabel.frame = NSMakeRect(32, curY, 600, 18);
    [container addSubview:self.dirStatsLabel];

    curY -= 58;
    self.dragDropView = [[FVDragDropView alloc] initWithFrame:NSMakeRect(30, curY, 870, 52)];
    self.dragDropView.delegate = self;
    __weak typeof(self) weakSelf = self;
    self.dragDropView.onDirectoryDropped = ^(NSString *path) {
        [weakSelf updateSelectedDirectory:path];
    };
    [container addSubview:self.dragDropView];

    curY -= 20;
    [self separatorWithY:curY inContainer:container];
    curY -= 15;

    // --- SECTION 2: Asymmetric Public Key ---
    NSTextField *sec2Title = [self labelWithText:@"2. 非对称加密公钥设置 (本地仅持有公钥，只能加密无法解密)" fontSize:14 bold:YES];
    sec2Title.frame = NSMakeRect(30, curY - 20, 600, 20);
    [container addSubview:sec2Title];

    curY -= 170;
    self.keyTabView = [[NSTabView alloc] initWithFrame:NSMakeRect(30, curY, 870, 160)];
    self.keyTabView.tabViewType = NSTopTabsBezelBorder;

    // Tab 1: Password Derivation
    NSTabViewItem *tabPassword = [[NSTabViewItem alloc] initWithIdentifier:@"password"];
    tabPassword.label = @"🔑 从密码派生/生成公钥";
    NSView *tab1View = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 120)];

    NSTextField *pwdPrompt = [self labelWithText:@"输入主密码 (用于生成非对称密钥对，私钥将导出由您妥善保存，程序仅装载公钥):" fontSize:12 bold:NO];
    pwdPrompt.frame = NSMakeRect(15, 80, 800, 18);
    [tab1View addSubview:pwdPrompt];

    self.passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(15, 48, 550, 26)];
    self.passwordField.placeholderString = @"输入安全主密码 (如: MySecretVault2026!)";
    [tab1View addSubview:self.passwordField];

    self.genKeypairButton = [NSButton buttonWithTitle:@"生成新密钥对并提取公钥" target:self action:@selector(generateKeypairClicked:)];
    self.genKeypairButton.frame = NSMakeRect(575, 47, 240, 28);
    self.genKeypairButton.bezelStyle = NSBezelStyleRounded;
    [tab1View addSubview:self.genKeypairButton];

    NSTextField *pwdHint = [self labelWithText:@"🛡️ 密码生成的私钥由您保存用于离线解密；本程序只保留公钥，任何人拿到此 Mac 也无法解密已上传数据。" fontSize:11 bold:NO];
    pwdHint.textColor = [NSColor systemBlueColor];
    pwdHint.frame = NSMakeRect(15, 20, 800, 18);
    [tab1View addSubview:pwdHint];

    tabPassword.view = tab1View;
    [self.keyTabView addTabViewItem:tabPassword];

    // Tab 2: Keychain Storage
    NSTabViewItem *tabKeychain = [[NSTabViewItem alloc] initWithIdentifier:@"keychain"];
    tabKeychain.label = @"🗄️ 从 macOS 钥匙串读取";
    NSView *tab2View = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 120)];

    NSTextField *kcPrompt = [self labelWithText:@"macOS 钥匙串服务标识符 (Generic Password):" fontSize:12 bold:NO];
    kcPrompt.frame = NSMakeRect(15, 80, 500, 18);
    [tab2View addSubview:kcPrompt];

    self.keychainServiceField = [[NSTextField alloc] initWithFrame:NSMakeRect(15, 48, 400, 26)];
    self.keychainServiceField.stringValue = @"com.flarevault.publickey";
    [tab2View addSubview:self.keychainServiceField];

    self.loadKeychainButton = [NSButton buttonWithTitle:@"从钥匙串读取公钥" target:self action:@selector(loadFromKeychainClicked:)];
    self.loadKeychainButton.frame = NSMakeRect(425, 47, 180, 28);
    self.loadKeychainButton.bezelStyle = NSBezelStyleRounded;
    [tab2View addSubview:self.loadKeychainButton];

    self.saveKeychainButton = [NSButton buttonWithTitle:@"保存当前公钥至钥匙串" target:self action:@selector(saveToKeychainClicked:)];
    self.saveKeychainButton.frame = NSMakeRect(615, 47, 180, 28);
    self.saveKeychainButton.bezelStyle = NSBezelStyleRounded;
    [tab2View addSubview:self.saveKeychainButton];

    tabKeychain.view = tab2View;
    [self.keyTabView addTabViewItem:tabKeychain];

    // Tab 3: PEM Import / Paste
    NSTabViewItem *tabPEM = [[NSTabViewItem alloc] initWithIdentifier:@"pem"];
    tabPEM.label = @"📋 导入/粘贴公钥 PEM";
    NSView *tab3View = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 120)];

    self.browsePemButton = [NSButton buttonWithTitle:@"选择 .pem / .pub 公钥文件..." target:self action:@selector(browsePemClicked:)];
    self.browsePemButton.frame = NSMakeRect(15, 80, 220, 28);
    self.browsePemButton.bezelStyle = NSBezelStyleRounded;
    [tab3View addSubview:self.browsePemButton];

    NSScrollView *pemScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(15, 10, 800, 65)];
    pemScroll.hasVerticalScroller = YES;
    pemScroll.borderType = NSBezelBorder;
    self.pemTextView = [[NSTextView alloc] initWithFrame:pemScroll.bounds];
    self.pemTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.pemTextView.font = [NSFont userFixedPitchFontOfSize:11];
    pemScroll.documentView = self.pemTextView;
    [tab3View addSubview:pemScroll];

    NSButton *applyPemBtn = [NSButton buttonWithTitle:@"解析并应用" target:self action:@selector(applyPemClicked:)];
    applyPemBtn.frame = NSMakeRect(245, 80, 120, 28);
    applyPemBtn.bezelStyle = NSBezelStyleRounded;
    [tab3View addSubview:applyPemBtn];

    tabPEM.view = tab3View;
    [self.keyTabView addTabViewItem:tabPEM];

    [container addSubview:self.keyTabView];

    // Key Status Badge
    curY -= 26;
    self.keyStatusLabel = [self labelWithText:@"⚠️ 未加载公钥 (请通过密码派生或导入公钥)" fontSize:12 bold:YES];
    self.keyStatusLabel.textColor = [NSColor systemOrangeColor];
    self.keyStatusLabel.frame = NSMakeRect(35, curY, 860, 20);
    [container addSubview:self.keyStatusLabel];

    curY -= 15;
    [self separatorWithY:curY inContainer:container];
    curY -= 15;

    // --- SECTION 3: Cloudflare Settings ---
    NSTextField *sec3Title = [self labelWithText:@"3. Cloudflare R2 存储配置" fontSize:14 bold:YES];
    sec3Title.frame = NSMakeRect(30, curY - 20, 400, 20);
    [container addSubview:sec3Title];

    curY -= 50;
    // Row 1: Account ID & Bucket Name
    NSTextField *lblAcc = [self labelWithText:@"Account ID:" fontSize:12 bold:NO];
    lblAcc.frame = NSMakeRect(30, curY + 22, 120, 18);
    [container addSubview:lblAcc];

    self.cfAccountIdField = [[NSTextField alloc] initWithFrame:NSMakeRect(30, curY, 410, 24)];
    self.cfAccountIdField.placeholderString = @"Cloudflare 账户 ID (例如: f81d4fae7dec...)";
    [container addSubview:self.cfAccountIdField];

    NSTextField *lblBkt = [self labelWithText:@"Bucket Name:" fontSize:12 bold:NO];
    lblBkt.frame = NSMakeRect(480, curY + 22, 120, 18);
    [container addSubview:lblBkt];

    self.cfBucketField = [[NSTextField alloc] initWithFrame:NSMakeRect(480, curY, 410, 24)];
    self.cfBucketField.placeholderString = @"R2 存储桶名称 (例如: my-backup-vault)";
    [container addSubview:self.cfBucketField];

    curY -= 50;
    // Row 2: Access Key ID & Secret Access Key
    NSTextField *lblAK = [self labelWithText:@"Access Key ID:" fontSize:12 bold:NO];
    lblAK.frame = NSMakeRect(30, curY + 22, 120, 18);
    [container addSubview:lblAK];

    self.cfAccessKeyField = [[NSTextField alloc] initWithFrame:NSMakeRect(30, curY, 410, 24)];
    self.cfAccessKeyField.placeholderString = @"R2 API Access Key ID";
    [container addSubview:self.cfAccessKeyField];

    NSTextField *lblSK = [self labelWithText:@"Secret Access Key:" fontSize:12 bold:NO];
    lblSK.frame = NSMakeRect(480, curY + 22, 150, 18);
    [container addSubview:lblSK];

    self.cfSecretKeyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(480, curY, 410, 24)];
    self.cfSecretKeyField.placeholderString = @"R2 API Secret Access Key";
    [container addSubview:self.cfSecretKeyField];

    curY -= 40;
    // Row 3: Remote Prefix & Test Connection Button
    NSTextField *lblPfx = [self labelWithText:@"远程路径前缀:" fontSize:12 bold:NO];
    lblPfx.frame = NSMakeRect(30, curY + 3, 100, 18);
    [container addSubview:lblPfx];

    self.cfPrefixField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, curY, 200, 24)];
    self.cfPrefixField.stringValue = @"backups/";
    [container addSubview:self.cfPrefixField];

    self.rememberCredsCheckbox = [NSButton checkboxWithTitle:@"安全保存凭据到 macOS 钥匙串" target:self action:nil];
    self.rememberCredsCheckbox.state = NSControlStateValueOn;
    self.rememberCredsCheckbox.frame = NSMakeRect(350, curY + 2, 220, 20);
    [container addSubview:self.rememberCredsCheckbox];

    self.testConnectionButton = [NSButton buttonWithTitle:@"测试 Cloudflare 连接" target:self action:@selector(testConnectionClicked:)];
    self.testConnectionButton.frame = NSMakeRect(680, curY - 2, 210, 28);
    self.testConnectionButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:self.testConnectionButton];

    curY -= 36;
    // Row 4: Lazy Upload Master Switch
    self.lazyUploadCheckbox = [NSButton checkboxWithTitle:@"启用惰性随机上传模式 (呈现离散调用与随机时序扰动，防内网流量突发误杀)"
                                                   target:self
                                                   action:@selector(lazyUploadCheckboxToggled:)];
    self.lazyUploadCheckbox.frame = NSMakeRect(30, curY + 2, 600, 20);
    self.lazyUploadCheckbox.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [container addSubview:self.lazyUploadCheckbox];

    curY -= 32;
    // Row 5: Preset Selector & Custom Intervals
    NSTextField *lblPreset = [self labelWithText:@"调用扰动预设:" fontSize:12 bold:NO];
    lblPreset.frame = NSMakeRect(45, curY + 2, 90, 18);
    [container addSubview:lblPreset];

    self.lazyPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, curY - 2, 230, 26) pullsDown:NO];
    [self.lazyPresetPopup addItemsWithTitles:@[
        @"轻度随机扰动 (1s ~ 4s 随机间隔)",
        @"中度随机离散 (2s ~ 8s 随机间隔)",
        @"深度隐匿低频 (6s ~ 20s 随机间隔)",
        @"自定义间隔范围..."
    ]];
    self.lazyPresetPopup.target = self;
    self.lazyPresetPopup.action = @selector(lazyPresetChanged:);
    [container addSubview:self.lazyPresetPopup];

    NSTextField *lblMin = [self labelWithText:@"最小(秒):" fontSize:12 bold:NO];
    lblMin.frame = NSMakeRect(385, curY + 2, 60, 18);
    [container addSubview:lblMin];

    self.lazyMinIntervalField = [[NSTextField alloc] initWithFrame:NSMakeRect(450, curY, 55, 24)];
    self.lazyMinIntervalField.stringValue = @"2.0";
    [container addSubview:self.lazyMinIntervalField];

    NSTextField *lblMax = [self labelWithText:@"最大(秒):" fontSize:12 bold:NO];
    lblMax.frame = NSMakeRect(515, curY + 2, 60, 18);
    [container addSubview:lblMax];

    self.lazyMaxIntervalField = [[NSTextField alloc] initWithFrame:NSMakeRect(580, curY, 55, 24)];
    self.lazyMaxIntervalField.stringValue = @"8.0";
    [container addSubview:self.lazyMaxIntervalField];

    self.lazyChunkJitterCheckbox = [NSButton checkboxWithTitle:@"随机变长分块 (5MB~8MB 扰动)" target:self action:nil];
    self.lazyChunkJitterCheckbox.state = NSControlStateValueOn;
    self.lazyChunkJitterCheckbox.frame = NSMakeRect(650, curY + 2, 230, 20);
    [container addSubview:self.lazyChunkJitterCheckbox];

    curY -= 24;
    self.lazyTipLabel = [self labelWithText:@"💡 惰性模式将整个归档拆解为动态变长分块，并在每次 HTTP 远程调用之间注入密码学时序随机抖动与突发模拟，打破特征聚集，避免触发内网 IDS/DLP/流量突发监测误杀。" fontSize:11 bold:NO];
    self.lazyTipLabel.textColor = [NSColor systemIndigoColor];
    self.lazyTipLabel.frame = NSMakeRect(45, curY, 840, 20);
    [container addSubview:self.lazyTipLabel];

    curY -= 18;
    [self separatorWithY:curY inContainer:container];
    curY -= 15;

    // --- SECTION 4: Action & Live Console ---
    self.actionButton = [NSButton buttonWithTitle:@"🚀 开始打包、加密并上传至 Cloudflare" target:self action:@selector(startPipelineClicked:)];
    self.actionButton.frame = NSMakeRect(30, curY - 36, 420, 36);
    self.actionButton.bezelStyle = NSBezelStyleRegularSquare;
    self.actionButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    [container addSubview:self.actionButton];

    self.cancelButton = [NSButton buttonWithTitle:@"取消任务" target:self action:@selector(cancelTaskClicked:)];
    self.cancelButton.frame = NSMakeRect(465, curY - 36, 120, 36);
    self.cancelButton.bezelStyle = NSBezelStyleRegularSquare;
    self.cancelButton.enabled = NO;
    [container addSubview:self.cancelButton];

    NSButton *clearLogBtn = [NSButton buttonWithTitle:@"清空日志" target:self action:@selector(clearLogClicked:)];
    clearLogBtn.frame = NSMakeRect(780, curY - 34, 110, 30);
    clearLogBtn.bezelStyle = NSBezelStyleRounded;
    [container addSubview:clearLogBtn];

    curY -= 50;
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(30, curY, 860, 16)];
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 1.0;
    self.progressBar.doubleValue = 0.0;
    [container addSubview:self.progressBar];

    curY -= 22;
    self.progressLabel = [self labelWithText:@"就绪" fontSize:11 bold:NO];
    self.progressLabel.textColor = [NSColor secondaryLabelColor];
    self.progressLabel.frame = NSMakeRect(30, curY, 860, 18);
    [container addSubview:self.progressLabel];

    curY -= 160;
    NSScrollView *logScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(30, curY, 860, 150)];
    logScroll.hasVerticalScroller = YES;
    logScroll.borderType = NSBezelBorder;

    self.logTextView = [[NSTextView alloc] initWithFrame:logScroll.bounds];
    self.logTextView.editable = NO;
    self.logTextView.font = [NSFont userFixedPitchFontOfSize:11];
    self.logTextView.backgroundColor = [NSColor textBackgroundColor];
    logScroll.documentView = self.logTextView;
    [container addSubview:logScroll];

    [self appendLog:@"FlareVault 已启动。本地仅持有公钥，具备极佳的端到端安全隔离特性。"];
}

- (NSTextField *)labelWithText:(NSString *)text fontSize:(CGFloat)size bold:(BOOL)bold {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont systemFontOfSize:size weight:NSFontWeightBold] : [NSFont systemFontOfSize:size];
    label.editable = NO;
    label.selectable = NO;
    label.drawsBackground = NO;
    return label;
}

- (NSBox *)separatorWithY:(CGFloat)y inContainer:(NSView *)container {
    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(30, y, 870, 1)];
    sep.boxType = NSBoxSeparator;
    [container addSubview:sep];
    return sep;
}

#pragma mark - Configuration Management

- (void)loadSavedConfiguration {
    FVConfigManager *cfg = [FVConfigManager sharedManager];
    if (cfg.lastDirectoryPath.length > 0) {
        [self updateSelectedDirectory:cfg.lastDirectoryPath];
    }
    if (cfg.cloudflareAccountId.length > 0) {
        self.cfAccountIdField.stringValue = cfg.cloudflareAccountId;
    }
    if (cfg.cloudflareBucketName.length > 0) {
        self.cfBucketField.stringValue = cfg.cloudflareBucketName;
    }
    if (cfg.cloudflareAccessKeyId.length > 0) {
        self.cfAccessKeyField.stringValue = cfg.cloudflareAccessKeyId;
    }
    if (cfg.cloudflareSecretAccessKey.length > 0) {
        self.cfSecretKeyField.stringValue = cfg.cloudflareSecretAccessKey;
    }
    if (cfg.cloudflareRemotePrefix.length > 0) {
        self.cfPrefixField.stringValue = cfg.cloudflareRemotePrefix;
    }

    if (cfg.lastPublicKeyPEM.length > 0) {
        NSError *err = nil;
        [[FVKeyManager sharedManager] loadPublicKeyFromPEM:cfg.lastPublicKeyPEM error:&err];
        [self updateKeyStatus];
    }

    self.lazyUploadCheckbox.state = cfg.lazyUploadEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.lazyMinIntervalField.stringValue = [NSString stringWithFormat:@"%.1f", cfg.lazyMinIntervalSeconds];
    self.lazyMaxIntervalField.stringValue = [NSString stringWithFormat:@"%.1f", cfg.lazyMaxIntervalSeconds];
    self.lazyChunkJitterCheckbox.state = cfg.lazyChunkJitter ? NSControlStateValueOn : NSControlStateValueOff;

    if (fabs(cfg.lazyMinIntervalSeconds - 1.0) < 0.1 && fabs(cfg.lazyMaxIntervalSeconds - 4.0) < 0.1) {
        [self.lazyPresetPopup selectItemAtIndex:0];
    } else if (fabs(cfg.lazyMinIntervalSeconds - 2.0) < 0.1 && fabs(cfg.lazyMaxIntervalSeconds - 8.0) < 0.1) {
        [self.lazyPresetPopup selectItemAtIndex:1];
    } else if (fabs(cfg.lazyMinIntervalSeconds - 6.0) < 0.1 && fabs(cfg.lazyMaxIntervalSeconds - 20.0) < 0.1) {
        [self.lazyPresetPopup selectItemAtIndex:2];
    } else {
        [self.lazyPresetPopup selectItemAtIndex:3]; // 自定义
    }
    [self updateLazyControlsState];
}

- (void)saveCurrentConfiguration {
    FVConfigManager *cfg = [FVConfigManager sharedManager];
    cfg.lastDirectoryPath = self.dirPathField.stringValue;
    cfg.cloudflareAccountId = self.cfAccountIdField.stringValue;
    cfg.cloudflareBucketName = self.cfBucketField.stringValue;
    cfg.cloudflareAccessKeyId = self.cfAccessKeyField.stringValue;
    cfg.cloudflareSecretAccessKey = self.cfSecretKeyField.stringValue;
    cfg.cloudflareRemotePrefix = self.cfPrefixField.stringValue;
    cfg.rememberCredentialsInKeychain = (self.rememberCredsCheckbox.state == NSControlStateValueOn);
    cfg.lastPublicKeyPEM = [FVKeyManager sharedManager].currentPublicKeyPEM;
    cfg.lazyUploadEnabled = (self.lazyUploadCheckbox.state == NSControlStateValueOn);
    cfg.lazyMinIntervalSeconds = [self.lazyMinIntervalField.stringValue doubleValue] ?: 2.0;
    cfg.lazyMaxIntervalSeconds = [self.lazyMaxIntervalField.stringValue doubleValue] ?: 8.0;
    cfg.lazyChunkJitter = (self.lazyChunkJitterCheckbox.state == NSControlStateValueOn);
    [cfg saveSettings];
}

- (void)lazyUploadCheckboxToggled:(id)sender {
    (void)sender;
    [self updateLazyControlsState];
}

- (void)lazyPresetChanged:(id)sender {
    (void)sender;
    NSInteger idx = self.lazyPresetPopup.indexOfSelectedItem;
    if (idx == 0) {
        self.lazyMinIntervalField.stringValue = @"1.0";
        self.lazyMaxIntervalField.stringValue = @"4.0";
    } else if (idx == 1) {
        self.lazyMinIntervalField.stringValue = @"2.0";
        self.lazyMaxIntervalField.stringValue = @"8.0";
    } else if (idx == 2) {
        self.lazyMinIntervalField.stringValue = @"6.0";
        self.lazyMaxIntervalField.stringValue = @"20.0";
    }
}

- (void)updateLazyControlsState {
    BOOL enabled = (self.lazyUploadCheckbox.state == NSControlStateValueOn);
    self.lazyPresetPopup.enabled = enabled;
    self.lazyMinIntervalField.enabled = enabled;
    self.lazyMaxIntervalField.enabled = enabled;
    self.lazyChunkJitterCheckbox.enabled = enabled;
    self.lazyTipLabel.alphaValue = enabled ? 1.0 : 0.4;
}

#pragma mark - Directory Selection

- (void)browseDirectoryClicked:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"选择此目录";
    panel.message = @"请选择需要打包并加密上传的目录";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [self updateSelectedDirectory:panel.URL.path];
        }
    }];
}

- (void)dirPathChanged:(id)sender {
    (void)sender;
    [self updateSelectedDirectory:self.dirPathField.stringValue];
}

- (void)updateSelectedDirectory:(NSString *)path {
    self.dirPathField.stringValue = path ?: @"";
    if (path.length == 0) {
        self.dirStatsLabel.stringValue = @"未选择目录";
        return;
    }

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        self.dirStatsLabel.stringValue = @"⚠️ 指定路径不是有效目录";
        self.dirStatsLabel.textColor = [NSColor systemRedColor];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FVDirectoryStats *stats = [FVArchiver inspectDirectoryAtPath:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.dirStatsLabel.textColor = [NSColor secondaryLabelColor];
            self.dirStatsLabel.stringValue = [NSString stringWithFormat:@"已选目录: '%@' (共 %lu 个文件, 约 %@)",
                                              [path lastPathComponent], (unsigned long)stats.fileCount, stats.formattedSize];
        });
    });
}

- (void)dragDropViewDidAcceptDirectoryPath:(NSString *)dirPath {
    [self updateSelectedDirectory:dirPath];
}

#pragma mark - Public Key Actions

- (void)updateKeyStatus {
    FVKeyManager *mgr = [FVKeyManager sharedManager];
    if (mgr.currentPublicKey) {
        self.keyStatusLabel.stringValue = [NSString stringWithFormat:@"🛡️ 已就绪: %@ | 指纹: %@ | 🔒 仅公钥模式（完全无法解密）",
                                           mgr.currentKeySummary, mgr.currentKeyFingerprint];
        self.keyStatusLabel.textColor = [NSColor systemGreenColor];
        if (mgr.currentPublicKeyPEM) {
            self.pemTextView.string = mgr.currentPublicKeyPEM;
        }
    } else {
        self.keyStatusLabel.stringValue = @"⚠️ 未加载公钥 (请通过密码派生或导入公钥)";
        self.keyStatusLabel.textColor = [NSColor systemOrangeColor];
    }
}

- (void)generateKeypairClicked:(id)sender {
    (void)sender;
    NSString *password = self.passwordField.stringValue;
    if (password.length == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"请输入主密码";
        alert.informativeText = @"主密码将用于对生成的私钥进行 AES-256 加密保护。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }

    // Prompt user to save private key backup
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.title = @"导出并备份解密私钥";
    savePanel.message = @"请将解密私钥保存到您的离线安全位置（如 U 盘或备份盘）。macOS 程序本身不会保存私钥！";
    savePanel.nameFieldStringValue = @"flarevault_private_key.pem";

    [savePanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !savePanel.URL) return;

        NSString *privatePEM = nil;
        NSError *err = nil;
        BOOL ok = [[FVKeyManager sharedManager] generateKeypairWithBits:2048
                                                       passwordProtect:password
                                                     outPrivateKeyPEM:&privatePEM
                                                                error:&err];
        if (!ok) {
            NSAlert *errAlert = [NSAlert alertWithError:err];
            [errAlert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }

        // Save private key to the chosen backup file
        [privatePEM writeToURL:savePanel.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // Clear password field to prevent holding secret in UI
        self.passwordField.stringValue = @"";

        [self updateKeyStatus];
        [self saveCurrentConfiguration];

        [self appendLog:[NSString stringWithFormat:@"🔑 成功生成非对称密钥对！私钥已备份至: %@", savePanel.URL.path]];
        [self appendLog:@"🛡️ 本机 App 已装载公钥，私钥已立即从内存抹除，当前只能执行加密操作。"];

        NSAlert *infoAlert = [[NSAlert alloc] init];
        infoAlert.messageText = @"公钥装载成功，私钥已安全导出！";
        infoAlert.informativeText = [NSString stringWithFormat:@"私钥已保存至:\n%@\n\n请妥善保管该私钥。本 macOS 应用仅保留公钥，任何人均无法通过本应用解密已备份数据。", savePanel.URL.path];
        [infoAlert beginSheetModalForWindow:self.window completionHandler:nil];
    }];
}

- (void)loadFromKeychainClicked:(id)sender {
    (void)sender;
    NSString *svc = self.keychainServiceField.stringValue;
    NSError *err = nil;
    BOOL ok = [[FVKeyManager sharedManager] loadPublicKeyFromKeychainWithService:svc account:nil error:&err];
    if (!ok) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"钥匙串查找失败";
        alert.informativeText = [NSString stringWithFormat:@"未在钥匙串中找到服务名为 '%@' 的公钥条目: %@", svc, err.localizedDescription];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }

    [self updateKeyStatus];
    [self saveCurrentConfiguration];
    [self appendLog:[NSString stringWithFormat:@"🗄️ 已从 macOS 钥匙串 (%@) 成功加载公钥。", svc]];
}

- (void)saveToKeychainClicked:(id)sender {
    (void)sender;
    if (![FVKeyManager sharedManager].currentPublicKey) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"无公钥可保存";
        alert.informativeText = @"请先生成或导入公钥。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }

    NSString *svc = self.keychainServiceField.stringValue;
    NSError *err = nil;
    BOOL ok = [[FVKeyManager sharedManager] saveCurrentPublicKeyToKeychainWithService:svc account:@"default" error:&err];
    if (ok) {
        [self appendLog:[NSString stringWithFormat:@"🗄️ 当前公钥已成功持久化保存至 macOS 钥匙串 (%@)。", svc]];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"保存成功";
        alert.informativeText = [NSString stringWithFormat:@"公钥已保存至钥匙串服务 '%@'。", svc];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    } else {
        NSAlert *errAlert = [NSAlert alertWithError:err];
        [errAlert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

- (void)browsePemClicked:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.prompt = @"导入公钥";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            BOOL ok = [[FVKeyManager sharedManager] loadPublicKeyFromFile:panel.URL.path error:&err];
            if (ok) {
                [self updateKeyStatus];
                [self saveCurrentConfiguration];
                [self appendLog:[NSString stringWithFormat:@"📋 已从文件导入公钥: %@", panel.URL.path]];
            } else {
                NSAlert *errAlert = [NSAlert alertWithError:err];
                [errAlert beginSheetModalForWindow:self.window completionHandler:nil];
            }
        }
    }];
}

- (void)applyPemClicked:(id)sender {
    (void)sender;
    NSString *pem = self.pemTextView.string;
    NSError *err = nil;
    BOOL ok = [[FVKeyManager sharedManager] loadPublicKeyFromPEM:pem error:&err];
    if (ok) {
        [self updateKeyStatus];
        [self saveCurrentConfiguration];
        [self appendLog:@"📋 已成功应用输入的 PEM 公钥。"];
    } else {
        NSAlert *errAlert = [NSAlert alertWithError:err];
        [errAlert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

#pragma mark - Cloudflare Connection Test

- (void)testConnectionClicked:(id)sender {
    (void)sender;
    [self saveCurrentConfiguration];
    FVCloudflareConfig *cfg = [[FVConfigManager sharedManager] cloudflareConfig];

    self.testConnectionButton.enabled = NO;
    [self appendLog:[NSString stringWithFormat:@"☁️ 正在测试连接 Cloudflare R2 存储桶 '%@'...", cfg.bucketName]];

    FVCloudflareUploader *uploader = [[FVCloudflareUploader alloc] initWithConfig:cfg];
    [uploader testConnectionWithCompletion:^(BOOL reachable, NSString * _Nullable message, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.testConnectionButton.enabled = YES;
            NSAlert *alert = [[NSAlert alloc] init];
            if (reachable) {
                alert.messageText = @"Cloudflare 连接成功！";
                alert.informativeText = message ?: @"已成功连通 Cloudflare R2 存储桶。";
                [self appendLog:[NSString stringWithFormat:@"✅ %@", alert.informativeText]];
            } else {
                alert.messageText = @"Cloudflare 连接失败";
                alert.informativeText = error.localizedDescription ?: message ?: @"无法访问指定存储桶。";
                [self appendLog:[NSString stringWithFormat:@"❌ [错误] %@", alert.informativeText]];
            }
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
        });
    }];
}

#pragma mark - Pipeline Execution

- (void)startPipelineClicked:(id)sender {
    (void)sender;
    [self saveCurrentConfiguration];

    NSString *dir = self.dirPathField.stringValue;
    SecKeyRef pubKey = [FVKeyManager sharedManager].currentPublicKey;
    FVCloudflareConfig *cfConfig = [[FVConfigManager sharedManager] cloudflareConfig];

    if (dir.length == 0) {
        [self showErrorAlert:@"请先选择需要打包的目录。"];
        return;
    }
    if (!pubKey) {
        [self showErrorAlert:@"未加载非对称公钥，请通过密码派生或导入公钥。"];
        return;
    }
    if (cfConfig.accountId.length == 0 || cfConfig.bucketName.length == 0 ||
        cfConfig.accessKeyId.length == 0 || cfConfig.secretAccessKey.length == 0) {
        [self showErrorAlert:@"请完整填写 Cloudflare R2 的 Account ID、Bucket Name、Access Key ID 与 Secret Key。"];
        return;
    }

    self.actionButton.enabled = NO;
    self.cancelButton.enabled = YES;
    self.progressBar.doubleValue = 0.0;
    self.progressLabel.stringValue = @"任务启动中...";

    self.currentPipeline = [[FVTaskPipeline alloc] initWithDirectoryPath:dir
                                                              publicKey:pubKey
                                                       cloudflareConfig:cfConfig];

    __weak typeof(self) weakSelf = self;
    [self.currentPipeline startWithLogHandler:^(NSString * _Nonnull message, BOOL isError) {
        (void)isError;
        [weakSelf appendLog:message];
    } progressHandler:^(NSString * _Nonnull stage, double progress, NSString * _Nonnull statusText) {
        weakSelf.progressBar.doubleValue = progress;
        weakSelf.progressLabel.stringValue = [NSString stringWithFormat:@"[%@] %@", stage, statusText];
    } completion:^(BOOL success, NSString * _Nullable remoteUrl, NSError * _Nullable error) {
        weakSelf.actionButton.enabled = YES;
        weakSelf.cancelButton.enabled = NO;
        if (success) {
            weakSelf.progressBar.doubleValue = 1.0;
            weakSelf.progressLabel.stringValue = @"🎉 任务全部完成，数据已加密上传至 Cloudflare R2。";
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"打包加密与上传成功！";
            alert.informativeText = [NSString stringWithFormat:@"您的目录已完成非对称加密并上传到 Cloudflare R2。\n\n远程对象地址:\n%@", remoteUrl ?: @""];
            [alert beginSheetModalForWindow:weakSelf.window completionHandler:nil];
        } else {
            weakSelf.progressLabel.stringValue = [NSString stringWithFormat:@"任务失败: %@", error.localizedDescription];
        }
        weakSelf.currentPipeline = nil;
    }];
}

- (void)cancelTaskClicked:(id)sender {
    (void)sender;
    if (self.currentPipeline) {
        [self appendLog:@"⚠️ 用户请求取消任务..."];
        [self.currentPipeline cancel];
        self.currentPipeline = nil;
    }
    self.actionButton.enabled = YES;
    self.cancelButton.enabled = NO;
    self.progressLabel.stringValue = @"任务已取消";
}

- (void)clearLogClicked:(id)sender {
    (void)sender;
    self.logTextView.string = @"";
}

- (void)appendLog:(NSString *)message {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *timeStr = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timeStr, message];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAttributedString *attrLine = [[NSAttributedString alloc] initWithString:line
                                                                       attributes:@{NSFontAttributeName: [NSFont userFixedPitchFontOfSize:11]}];
        [self.logTextView.textStorage appendAttributedString:attrLine];
        [self.logTextView scrollToEndOfDocument:nil];
    });
}

- (void)showErrorAlert:(NSString *)msg {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"提示";
    alert.informativeText = msg;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

@end
