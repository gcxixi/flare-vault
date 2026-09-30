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
#import "../Core/FVSnapshotManager.h"

@interface FVMainWindowController () <NSTableViewDataSource, NSTableViewDelegate, FVDragDropViewDelegate, NSTabViewDelegate>

// Directory UI
@property (nonatomic, strong) NSTableView *directoriesTableView;
@property (nonatomic, strong) NSButton *addDirectoryButton;
@property (nonatomic, strong) NSButton *removeDirectoryButton;
@property (nonatomic, strong) NSButton *clearDirectoriesButton;
@property (nonatomic, strong) NSTextField *dirStatsLabel;
@property (nonatomic, strong) NSButton *incrementalBackupCheckbox;
@property (nonatomic, strong) NSButton *defaultExcludesCheckbox;
@property (nonatomic, strong) NSTextField *customExcludesField;
@property (nonatomic, strong) NSTextField *dirPathField; // legacy compatibility

// Key UI
@property (nonatomic, strong) NSSegmentedControl *keySourceControl;
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
    NSRect frame = NSMakeRect(120, 100, 900, 810);
    NSWindowStyleMask style = NSWindowStyleMaskTitled |
                              NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:style
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = @"FlareVault";
    win.minSize = NSMakeSize(860, 720);

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

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 790)];
    outerScrollView.documentView = container;
    [contentView addSubview:outerScrollView];

    CGFloat curY = 760;

    // --- Header ---
    NSTextField *titleLabel = [self labelWithText:@"FlareVault" fontSize:16 bold:YES];
    titleLabel.frame = NSMakeRect(24, curY, 150, 20);
    [container addSubview:titleLabel];

    NSTextField *subtitleLabel = [self labelWithText:@"macOS 目录非对称加密备份客户端" fontSize:11 bold:NO];
    subtitleLabel.textColor = [NSColor secondaryLabelColor];
    subtitleLabel.alignment = NSTextAlignmentRight;
    subtitleLabel.frame = NSMakeRect(500, curY + 2, 376, 16);
    [container addSubview:subtitleLabel];

    curY -= 14;
    [self separatorWithY:curY inContainer:container];

    // --- SECTION 1: 源目录 ---
    curY -= 22;
    NSTextField *sec1Title = [self labelWithText:@"备份源目录 (支持多目录批量配置)" fontSize:12 bold:YES];
    sec1Title.frame = NSMakeRect(24, curY, 300, 16);
    [container addSubview:sec1Title];

    self.dirStatsLabel = [self labelWithText:@"共配置 0 个目录" fontSize:11 bold:NO];
    self.dirStatsLabel.textColor = [NSColor secondaryLabelColor];
    self.dirStatsLabel.alignment = NSTextAlignmentRight;
    self.dirStatsLabel.frame = NSMakeRect(460, curY, 416, 16);
    [container addSubview:self.dirStatsLabel];

    curY -= 104;
    NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, curY, 852, 100)];
    tableScroll.hasVerticalScroller = YES;
    tableScroll.hasHorizontalScroller = NO;
    tableScroll.borderType = NSBezelBorder;

    self.directoriesTableView = [[NSTableView alloc] initWithFrame:tableScroll.bounds];
    self.directoriesTableView.usesAlternatingRowBackgroundColors = YES;
    self.directoriesTableView.rowHeight = 22;
    self.directoriesTableView.headerView = [[NSTableHeaderView alloc] init];
    self.directoriesTableView.dataSource = self;
    self.directoriesTableView.delegate = self;
    [self.directoriesTableView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    NSTableColumn *colEnabled = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    colEnabled.title = @"启用";
    colEnabled.width = 44;
    colEnabled.resizingMask = NSTableColumnNoResizing;
    [self.directoriesTableView addTableColumn:colEnabled];

    NSTableColumn *colName = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    colName.title = @"目录名称";
    colName.width = 160;
    colName.resizingMask = NSTableColumnUserResizingMask;
    [self.directoriesTableView addTableColumn:colName];

    NSTableColumn *colSnap = [[NSTableColumn alloc] initWithIdentifier:@"snapshot"];
    colSnap.title = @"快照模式";
    colSnap.width = 160;
    colSnap.resizingMask = NSTableColumnUserResizingMask;
    [self.directoriesTableView addTableColumn:colSnap];

    NSTableColumn *colPath = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    colPath.title = @"完整路径";
    colPath.width = 450;
    colPath.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
    [self.directoriesTableView addTableColumn:colPath];

    tableScroll.documentView = self.directoriesTableView;
    [container addSubview:tableScroll];

    // Button & Setting Controls Row below table
    curY -= 28;
    self.addDirectoryButton = [NSButton buttonWithTitle:@"添加目录..." target:self action:@selector(addDirectoryClicked:)];
    self.addDirectoryButton.frame = NSMakeRect(24, curY, 100, 24);
    self.addDirectoryButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:self.addDirectoryButton];

    self.removeDirectoryButton = [NSButton buttonWithTitle:@"移除" target:self action:@selector(removeDirectoryClicked:)];
    self.removeDirectoryButton.frame = NSMakeRect(128, curY, 70, 24);
    self.removeDirectoryButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:self.removeDirectoryButton];

    self.clearDirectoriesButton = [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearDirectoriesClicked:)];
    self.clearDirectoriesButton.frame = NSMakeRect(202, curY, 70, 24);
    self.clearDirectoriesButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:self.clearDirectoriesButton];

    self.incrementalBackupCheckbox = [NSButton checkboxWithTitle:@"增量备份 (基于快照差异)"
                                                          target:self
                                                          action:@selector(incrementalBackupToggled:)];
    self.incrementalBackupCheckbox.state = [FVConfigManager sharedManager].incrementalBackupEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.incrementalBackupCheckbox.frame = NSMakeRect(462, curY + 2, 178, 18);
    self.incrementalBackupCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    [container addSubview:self.incrementalBackupCheckbox];

    self.defaultExcludesCheckbox = [NSButton checkboxWithTitle:@"排除开发与缓存 (node_modules 等)"
                                                        target:self
                                                        action:@selector(excludeSettingsChanged:)];
    self.defaultExcludesCheckbox.state = NSControlStateValueOn;
    self.defaultExcludesCheckbox.frame = NSMakeRect(646, curY + 2, 230, 18);
    self.defaultExcludesCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    [container addSubview:self.defaultExcludesCheckbox];

    curY -= 26;
    NSTextField *lblCustEx = [self labelWithText:@"自定义排除:" fontSize:11 bold:NO];
    lblCustEx.frame = NSMakeRect(24, curY + 2, 70, 16);
    [container addSubview:lblCustEx];

    self.customExcludesField = [[NSTextField alloc] initWithFrame:NSMakeRect(96, curY, 780, 22)];
    self.customExcludesField.placeholderString = @"通配符规则，以逗号或空格分隔 (例如: *.tmp, *.log, cache/*)";
    self.customExcludesField.font = [NSFont userFixedPitchFontOfSize:11];
    self.customExcludesField.target = self;
    self.customExcludesField.action = @selector(excludeSettingsChanged:);
    [container addSubview:self.customExcludesField];

    curY -= 14;
    [self separatorWithY:curY inContainer:container];

    // --- SECTION 2: 加密公钥 ---
    curY -= 22;
    NSTextField *sec2Title = [self labelWithText:@"加密公钥 (非对称单向加密 · 本地无私钥)" fontSize:12 bold:YES];
    sec2Title.frame = NSMakeRect(24, curY, 350, 16);
    [container addSubview:sec2Title];

    self.keySourceControl = [NSSegmentedControl segmentedControlWithLabels:@[@"主密码派生", @"系统钥匙串", @"PEM 公钥"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(keySourceChanged:)];
    self.keySourceControl.selectedSegment = 0;
    self.keySourceControl.frame = NSMakeRect(602, curY - 3, 274, 24);
    [container addSubview:self.keySourceControl];

    curY -= 36;
    self.keyTabView = [[NSTabView alloc] initWithFrame:NSMakeRect(24, curY, 852, 30)];
    self.keyTabView.tabViewType = NSNoTabsNoBorder;

    // Tab 1: 密码派生
    NSTabViewItem *tabPassword = [[NSTabViewItem alloc] initWithIdentifier:@"password"];
    NSView *tab1View = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 852, 30)];

    NSTextField *lblPwd = [self labelWithText:@"主密码:" fontSize:11 bold:NO];
    lblPwd.frame = NSMakeRect(0, 5, 50, 16);
    [tab1View addSubview:lblPwd];

    self.passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(54, 2, 630, 24)];
    self.passwordField.placeholderString = @"输入主密码以生成并导出密钥对";
    [tab1View addSubview:self.passwordField];

    self.genKeypairButton = [NSButton buttonWithTitle:@"生成并装载公钥..." target:self action:@selector(generateKeypairClicked:)];
    self.genKeypairButton.frame = NSMakeRect(694, 1, 158, 26);
    self.genKeypairButton.bezelStyle = NSBezelStyleRounded;
    [tab1View addSubview:self.genKeypairButton];

    tabPassword.view = tab1View;
    [self.keyTabView addTabViewItem:tabPassword];

    // Tab 2: 系统钥匙串
    NSTabViewItem *tabKeychain = [[NSTabViewItem alloc] initWithIdentifier:@"keychain"];
    NSView *tab2View = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 852, 30)];

    NSTextField *lblKc = [self labelWithText:@"服务标识:" fontSize:11 bold:NO];
    lblKc.frame = NSMakeRect(0, 5, 60, 16);
    [tab2View addSubview:lblKc];

    self.keychainServiceField = [[NSTextField alloc] initWithFrame:NSMakeRect(64, 2, 510, 24)];
    self.keychainServiceField.stringValue = @"com.flarevault.publickey";
    [tab2View addSubview:self.keychainServiceField];

    self.loadKeychainButton = [NSButton buttonWithTitle:@"从钥匙串读取" target:self action:@selector(loadFromKeychainClicked:)];
    self.loadKeychainButton.frame = NSMakeRect(584, 1, 130, 26);
    self.loadKeychainButton.bezelStyle = NSBezelStyleRounded;
    [tab2View addSubview:self.loadKeychainButton];

    self.saveKeychainButton = [NSButton buttonWithTitle:@"保存当前公钥" target:self action:@selector(saveToKeychainClicked:)];
    self.saveKeychainButton.frame = NSMakeRect(722, 1, 130, 26);
    self.saveKeychainButton.bezelStyle = NSBezelStyleRounded;
    [tab2View addSubview:self.saveKeychainButton];

    tabKeychain.view = tab2View;
    [self.keyTabView addTabViewItem:tabKeychain];

    // Tab 3: PEM 导入
    NSTabViewItem *tabPEM = [[NSTabViewItem alloc] initWithIdentifier:@"pem"];
    NSView *tab3View = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 852, 30)];

    self.browsePemButton = [NSButton buttonWithTitle:@"选择 PEM 文件..." target:self action:@selector(browsePemClicked:)];
    self.browsePemButton.frame = NSMakeRect(0, 1, 140, 26);
    self.browsePemButton.bezelStyle = NSBezelStyleRounded;
    [tab3View addSubview:self.browsePemButton];

    NSScrollView *pemScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(148, 2, 538, 24)];
    pemScroll.hasVerticalScroller = NO;
    pemScroll.borderType = NSBezelBorder;
    self.pemTextView = [[NSTextView alloc] initWithFrame:pemScroll.bounds];
    self.pemTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.pemTextView.font = [NSFont userFixedPitchFontOfSize:10];
    pemScroll.documentView = self.pemTextView;
    [tab3View addSubview:pemScroll];

    NSButton *applyPemBtn = [NSButton buttonWithTitle:@"解析应用" target:self action:@selector(applyPemClicked:)];
    applyPemBtn.frame = NSMakeRect(694, 1, 158, 26);
    applyPemBtn.bezelStyle = NSBezelStyleRounded;
    [tab3View addSubview:applyPemBtn];

    tabPEM.view = tab3View;
    [self.keyTabView addTabViewItem:tabPEM];

    [container addSubview:self.keyTabView];

    // Key Status
    curY -= 22;
    self.keyStatusLabel = [self labelWithText:@"公钥状态: 未加载 (请生成或导入公钥)" fontSize:11 bold:NO];
    self.keyStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.keyStatusLabel.frame = NSMakeRect(24, curY, 852, 16);
    [container addSubview:self.keyStatusLabel];

    curY -= 14;
    [self separatorWithY:curY inContainer:container];

    // --- SECTION 3: Cloudflare R2 存储 ---
    curY -= 22;
    NSTextField *sec3Title = [self labelWithText:@"Cloudflare R2 存储" fontSize:12 bold:YES];
    sec3Title.frame = NSMakeRect(24, curY, 300, 16);
    [container addSubview:sec3Title];

    // Row 1: Account ID & Bucket Name (2 cols, 414px each, gap 24px)
    curY -= 40;
    NSTextField *lblAcc = [self labelWithText:@"Account ID:" fontSize:11 bold:NO];
    lblAcc.textColor = [NSColor secondaryLabelColor];
    lblAcc.frame = NSMakeRect(24, curY + 20, 200, 14);
    [container addSubview:lblAcc];

    self.cfAccountIdField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, curY, 414, 22)];
    self.cfAccountIdField.placeholderString = @"例如: f81d4fae7dec89304b7c125e9821a0f4";
    [container addSubview:self.cfAccountIdField];

    NSTextField *lblBkt = [self labelWithText:@"Bucket Name:" fontSize:11 bold:NO];
    lblBkt.textColor = [NSColor secondaryLabelColor];
    lblBkt.frame = NSMakeRect(462, curY + 20, 200, 14);
    [container addSubview:lblBkt];

    self.cfBucketField = [[NSTextField alloc] initWithFrame:NSMakeRect(462, curY, 414, 22)];
    self.cfBucketField.placeholderString = @"例如: my-backup-vault";
    [container addSubview:self.cfBucketField];

    // Row 2: Access Key ID & Secret Access Key
    curY -= 40;
    NSTextField *lblAK = [self labelWithText:@"Access Key ID:" fontSize:11 bold:NO];
    lblAK.textColor = [NSColor secondaryLabelColor];
    lblAK.frame = NSMakeRect(24, curY + 20, 200, 14);
    [container addSubview:lblAK];

    self.cfAccessKeyField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, curY, 414, 22)];
    self.cfAccessKeyField.placeholderString = @"R2 API Access Key ID";
    [container addSubview:self.cfAccessKeyField];

    NSTextField *lblSK = [self labelWithText:@"Secret Access Key:" fontSize:11 bold:NO];
    lblSK.textColor = [NSColor secondaryLabelColor];
    lblSK.frame = NSMakeRect(462, curY + 20, 200, 14);
    [container addSubview:lblSK];

    self.cfSecretKeyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(462, curY, 414, 22)];
    self.cfSecretKeyField.placeholderString = @"R2 API Secret Access Key";
    [container addSubview:self.cfSecretKeyField];

    // Row 3: Prefix (left) + Remember in Keychain & Test Connection (right)
    curY -= 30;
    NSTextField *lblPfx = [self labelWithText:@"存储前缀:" fontSize:11 bold:NO];
    lblPfx.frame = NSMakeRect(24, curY + 2, 55, 16);
    [container addSubview:lblPfx];

    self.cfPrefixField = [[NSTextField alloc] initWithFrame:NSMakeRect(82, curY, 356, 22)];
    self.cfPrefixField.stringValue = @"backups/";
    [container addSubview:self.cfPrefixField];

    self.rememberCredsCheckbox = [NSButton checkboxWithTitle:@"保存凭据至钥匙串" target:self action:nil];
    self.rememberCredsCheckbox.state = NSControlStateValueOn;
    self.rememberCredsCheckbox.frame = NSMakeRect(462, curY + 1, 230, 20);
    self.rememberCredsCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    [container addSubview:self.rememberCredsCheckbox];

    self.testConnectionButton = [NSButton buttonWithTitle:@"测试连接" target:self action:@selector(testConnectionClicked:)];
    self.testConnectionButton.frame = NSMakeRect(756, curY - 1, 120, 24);
    self.testConnectionButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:self.testConnectionButton];

    // Row 4: Stochastic Upload
    curY -= 28;
    self.lazyUploadCheckbox = [NSButton checkboxWithTitle:@"启用惰性上传 (离散调用与时序抖动)"
                                                   target:self
                                                   action:@selector(lazyUploadCheckboxToggled:)];
    self.lazyUploadCheckbox.frame = NSMakeRect(24, curY + 1, 250, 20);
    self.lazyUploadCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [container addSubview:self.lazyUploadCheckbox];

    self.lazyPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(280, curY - 2, 170, 24) pullsDown:NO];
    [self.lazyPresetPopup addItemsWithTitles:@[
        @"轻度扰动 (1s ~ 4s)",
        @"中度离散 (2s ~ 8s)",
        @"低频隐匿 (6s ~ 20s)",
        @"自定义..."
    ]];
    self.lazyPresetPopup.font = [NSFont systemFontOfSize:11];
    self.lazyPresetPopup.target = self;
    self.lazyPresetPopup.action = @selector(lazyPresetChanged:);
    [container addSubview:self.lazyPresetPopup];

    NSTextField *lblMin = [self labelWithText:@"间隔:" fontSize:11 bold:NO];
    lblMin.frame = NSMakeRect(462, curY + 2, 32, 16);
    [container addSubview:lblMin];

    self.lazyMinIntervalField = [[NSTextField alloc] initWithFrame:NSMakeRect(496, curY, 36, 20)];
    self.lazyMinIntervalField.stringValue = @"2.0";
    self.lazyMinIntervalField.font = [NSFont systemFontOfSize:11];
    [container addSubview:self.lazyMinIntervalField];

    NSTextField *lblTilde = [self labelWithText:@"~" fontSize:11 bold:NO];
    lblTilde.frame = NSMakeRect(536, curY + 2, 10, 16);
    [container addSubview:lblTilde];

    self.lazyMaxIntervalField = [[NSTextField alloc] initWithFrame:NSMakeRect(548, curY, 36, 20)];
    self.lazyMaxIntervalField.stringValue = @"8.0";
    self.lazyMaxIntervalField.font = [NSFont systemFontOfSize:11];
    [container addSubview:self.lazyMaxIntervalField];

    NSTextField *lblSec = [self labelWithText:@"秒" fontSize:11 bold:NO];
    lblSec.frame = NSMakeRect(588, curY + 2, 18, 16);
    [container addSubview:lblSec];

    self.lazyChunkJitterCheckbox = [NSButton checkboxWithTitle:@"随机变长分块 (5MB~8MB)" target:self action:nil];
    self.lazyChunkJitterCheckbox.state = NSControlStateValueOn;
    self.lazyChunkJitterCheckbox.frame = NSMakeRect(618, curY + 1, 258, 20);
    self.lazyChunkJitterCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    [container addSubview:self.lazyChunkJitterCheckbox];

    curY -= 14;
    [self separatorWithY:curY inContainer:container];

    // --- SECTION 4: 任务控制与日志 ---
    curY -= 24;
    NSTextField *sec4Title = [self labelWithText:@"任务控制与日志" fontSize:12 bold:YES];
    sec4Title.frame = NSMakeRect(24, curY + 4, 150, 16);
    [container addSubview:sec4Title];

    self.actionButton = [NSButton buttonWithTitle:@"开始打包上传" target:self action:@selector(startPipelineClicked:)];
    self.actionButton.frame = NSMakeRect(520, curY, 160, 26);
    self.actionButton.bezelStyle = NSBezelStyleRounded;
    self.actionButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.actionButton.keyEquivalent = @"\r";
    [container addSubview:self.actionButton];

    self.cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelTaskClicked:)];
    self.cancelButton.frame = NSMakeRect(690, curY, 88, 26);
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.enabled = NO;
    [container addSubview:self.cancelButton];

    NSButton *clearLogBtn = [NSButton buttonWithTitle:@"清空日志" target:self action:@selector(clearLogClicked:)];
    clearLogBtn.frame = NSMakeRect(788, curY, 88, 26);
    clearLogBtn.bezelStyle = NSBezelStyleRounded;
    [container addSubview:clearLogBtn];

    curY -= 22;
    self.progressLabel = [self labelWithText:@"就绪" fontSize:11 bold:NO];
    self.progressLabel.textColor = [NSColor secondaryLabelColor];
    self.progressLabel.frame = NSMakeRect(24, curY, 852, 14);
    [container addSubview:self.progressLabel];

    curY -= 12;
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, curY, 852, 8)];
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 1.0;
    self.progressBar.doubleValue = 0.0;
    [container addSubview:self.progressBar];

    NSScrollView *logScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 24, 852, curY - 24 - 8)];
    logScroll.hasVerticalScroller = YES;
    logScroll.borderType = NSBezelBorder;

    self.logTextView = [[NSTextView alloc] initWithFrame:logScroll.bounds];
    self.logTextView.editable = NO;
    self.logTextView.font = [NSFont userFixedPitchFontOfSize:11];
    self.logTextView.backgroundColor = [NSColor textBackgroundColor];
    logScroll.documentView = self.logTextView;
    [container addSubview:logScroll];

    [self appendLog:@"FlareVault 已就绪。模式: 仅公钥加密 (客户端无私钥)。"];
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
    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(24, y, 852, 1)];
    sep.boxType = NSBoxSeparator;
    [container addSubview:sep];
    return sep;
}

#pragma mark - Configuration Management

- (void)loadSavedConfiguration {
    FVConfigManager *cfg = [FVConfigManager sharedManager];
    [self.directoriesTableView reloadData];
    [self updateDirectoriesStatsSummary];

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

    self.defaultExcludesCheckbox.state = cfg.useDefaultExcludes ? NSControlStateValueOn : NSControlStateValueOff;
    self.incrementalBackupCheckbox.state = cfg.incrementalBackupEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (cfg.customExcludeString.length > 0) {
        self.customExcludesField.stringValue = cfg.customExcludeString;
    }
}

- (void)saveCurrentConfiguration {
    FVConfigManager *cfg = [FVConfigManager sharedManager];
    cfg.lastDirectoryPath = [cfg.enabledDirectoryPaths firstObject] ?: @"";
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
    cfg.useDefaultExcludes = (self.defaultExcludesCheckbox.state == NSControlStateValueOn);
    cfg.customExcludeString = self.customExcludesField.stringValue;
    cfg.incrementalBackupEnabled = (self.incrementalBackupCheckbox.state == NSControlStateValueOn);
    [cfg saveSettings];
}

- (void)incrementalBackupToggled:(id)sender {
    (void)sender;
    [self saveCurrentConfiguration];
    [self.directoriesTableView reloadData];
    [self updateDirectoriesStatsSummary];
}

- (void)excludeSettingsChanged:(id)sender {
    (void)sender;
    [self saveCurrentConfiguration];
    [self.directoriesTableView reloadData];
    [self updateDirectoriesStatsSummary];
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
}

#pragma mark - Directory Selection & TableView

- (void)updateDirectoriesStatsSummary {
    NSArray<FVDirectoryConfig *> *configs = [FVConfigManager sharedManager].directoryConfigs;
    NSUInteger total = configs.count;
    NSUInteger enabled = 0;
    for (FVDirectoryConfig *cfg in configs) {
        if (cfg.enabled) enabled++;
    }
    if (total == 0) {
        self.dirStatsLabel.stringValue = @"未添加目录 (点击下方添加或拖拽文件夹至列表)";
        self.dirStatsLabel.textColor = [NSColor secondaryLabelColor];
    } else {
        self.dirStatsLabel.stringValue = [NSString stringWithFormat:@"已配置 %lu 个目录 (已启用 %lu 个)", (unsigned long)total, (unsigned long)enabled];
        self.dirStatsLabel.textColor = (enabled > 0) ? [NSColor secondaryLabelColor] : [NSColor systemOrangeColor];
    }
}

- (void)addDirectoryClicked:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"添加目录";
    panel.message = @"请选择需要打包并加密上传的目录（支持按住 Command 或 Shift 多选）";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URLs.count > 0) {
            for (NSURL *url in panel.URLs) {
                [[FVConfigManager sharedManager] addDirectoryPath:url.path];
            }
            [self.directoriesTableView reloadData];
            [self updateDirectoriesStatsSummary];
        }
    }];
}

- (void)removeDirectoryClicked:(id)sender {
    (void)sender;
    NSInteger row = self.directoriesTableView.selectedRow;
    NSArray<FVDirectoryConfig *> *configs = [FVConfigManager sharedManager].directoryConfigs;
    if (row >= 0 && row < (NSInteger)configs.count) {
        FVDirectoryConfig *cfg = configs[row];
        [[FVConfigManager sharedManager] removeDirectoryPath:cfg.path];
        [self.directoriesTableView reloadData];
        [self updateDirectoriesStatsSummary];
    }
}

- (void)clearDirectoriesClicked:(id)sender {
    (void)sender;
    NSArray<FVDirectoryConfig *> *configs = [FVConfigManager sharedManager].directoryConfigs;
    if (configs.count == 0) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"清空所有目录";
    alert.informativeText = @"确定要从列表中移除所有配置的目录吗？（不会删除磁盘实际文件）";
    [alert addButtonWithTitle:@"清空"];
    [alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSAlertFirstButtonReturn) {
            [[FVConfigManager sharedManager] clearDirectories];
            [self.directoriesTableView reloadData];
            [self updateDirectoriesStatsSummary];
        }
    }];
}

- (void)directoryRowCheckboxToggled:(NSButton *)sender {
    NSInteger row = sender.tag;
    NSArray<FVDirectoryConfig *> *configs = [FVConfigManager sharedManager].directoryConfigs;
    if (row >= 0 && row < (NSInteger)configs.count) {
        FVDirectoryConfig *cfg = configs[row];
        BOOL enabled = (sender.state == NSControlStateValueOn);
        [[FVConfigManager sharedManager] setDirectoryPath:cfg.path enabled:enabled];
        [self updateDirectoriesStatsSummary];
    }
}

#pragma mark - NSTableViewDataSource & NSTableViewDelegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)[FVConfigManager sharedManager].directoryConfigs.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray<FVDirectoryConfig *> *configs = [FVConfigManager sharedManager].directoryConfigs;
    if (row < 0 || row >= (NSInteger)configs.count) return nil;
    FVDirectoryConfig *config = configs[row];

    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"enabled"]) {
        NSButton *chk = [tableView makeViewWithIdentifier:@"enabledCell" owner:self];
        if (!chk || ![chk isKindOfClass:[NSButton class]]) {
            chk = [NSButton checkboxWithTitle:@"" target:self action:@selector(directoryRowCheckboxToggled:)];
            chk.identifier = @"enabledCell";
        }
        chk.tag = row;
        chk.state = config.enabled ? NSControlStateValueOn : NSControlStateValueOff;
        return chk;
    } else if ([identifier isEqualToString:@"name"]) {
        NSTextField *tf = [tableView makeViewWithIdentifier:@"nameCell" owner:self];
        if (!tf || ![tf isKindOfClass:[NSTextField class]]) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = @"nameCell";
            tf.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        }
        tf.stringValue = config.displayName ?: @"";
        return tf;
    } else if ([identifier isEqualToString:@"snapshot"]) {
        NSTextField *tf = [tableView makeViewWithIdentifier:@"snapCell" owner:self];
        if (!tf || ![tf isKindOfClass:[NSTextField class]]) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = @"snapCell";
            tf.font = [NSFont systemFontOfSize:10];
            tf.textColor = [NSColor secondaryLabelColor];
        }
        BOOL isInc = [FVConfigManager sharedManager].incrementalBackupEnabled;
        if (isInc) {
            NSDictionary *snap = [[FVSnapshotManager sharedManager] snapshotInfoForDirectory:config.path];
            if (snap) {
                tf.stringValue = [NSString stringWithFormat:@"增量快照 #%@", snap[@"sequenceNumber"]];
            } else {
                tf.stringValue = @"基线未建立";
            }
        } else {
            tf.stringValue = @"全量打包";
        }
        return tf;
    } else if ([identifier isEqualToString:@"path"]) {
        NSTextField *tf = [tableView makeViewWithIdentifier:@"pathCell" owner:self];
        if (!tf || ![tf isKindOfClass:[NSTextField class]]) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = @"pathCell";
            tf.font = [NSFont userFixedPitchFontOfSize:10];
            tf.textColor = [NSColor secondaryLabelColor];
            tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        }
        tf.stringValue = config.path ?: @"";
        return tf;
    }

    return nil;
}

#pragma mark - NSTableView Drag and Drop

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    (void)tableView; (void)row; (void)dropOperation;
    NSPasteboard *pb = [info draggingPasteboard];
    if ([pb canReadObjectForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation {
    (void)tableView; (void)row; (void)dropOperation;
    NSPasteboard *pb = [info draggingPasteboard];
    NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    BOOL added = NO;
    for (NSURL *url in urls) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
            [[FVConfigManager sharedManager] addDirectoryPath:url.path];
            added = YES;
        }
    }
    if (added) {
        [self.directoriesTableView reloadData];
        [self updateDirectoriesStatsSummary];
    }
    return added;
}

#pragma mark - Legacy Compatibility

- (NSTextField *)dirPathField {
    if (!_dirPathField) {
        _dirPathField = [[NSTextField alloc] init];
    }
    NSArray<NSString *> *dirs = [[FVConfigManager sharedManager] enabledDirectoryPaths];
    _dirPathField.stringValue = dirs.firstObject ?: @"";
    return _dirPathField;
}

- (void)updateSelectedDirectory:(NSString *)path {
    if (path.length > 0) {
        [[FVConfigManager sharedManager] addDirectoryPath:path];
        [self.directoriesTableView reloadData];
        [self updateDirectoriesStatsSummary];
    }
}

- (void)dragDropViewDidAcceptDirectoryPath:(NSString *)dirPath {
    [self updateSelectedDirectory:dirPath];
}

#pragma mark - Public Key Actions

- (void)updateKeyStatus {
    FVKeyManager *mgr = [FVKeyManager sharedManager];
    if (mgr.currentPublicKey) {
        self.keyStatusLabel.stringValue = [NSString stringWithFormat:@"公钥状态: 已加载 %@ | 指纹: %@ | 模式: 仅公钥 (客户端无私钥)",
                                           mgr.currentKeySummary, mgr.currentKeyFingerprint];
        self.keyStatusLabel.textColor = [NSColor systemGreenColor];
        if (mgr.currentPublicKeyPEM) {
            self.pemTextView.string = mgr.currentPublicKeyPEM;
        }
    } else {
        self.keyStatusLabel.stringValue = @"公钥状态: 未加载 (请派生或导入公钥)";
        self.keyStatusLabel.textColor = [NSColor secondaryLabelColor];
    }
}

- (void)keySourceChanged:(NSSegmentedControl *)sender {
    if (sender.selectedSegment >= 0 && sender.selectedSegment < self.keyTabView.numberOfTabViewItems) {
        [self.keyTabView selectTabViewItemAtIndex:sender.selectedSegment];
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

        [self appendLog:[NSString stringWithFormat:@"已生成非对称密钥对，私钥已备份至: %@", savePanel.URL.path]];
        [self appendLog:@"客户端已装载公钥，私钥已从内存清除。"];

        NSAlert *infoAlert = [[NSAlert alloc] init];
        infoAlert.messageText = @"密钥对生成完成";
        infoAlert.informativeText = [NSString stringWithFormat:@"私钥已保存至:\n%@\n\n请妥善保管私钥。本客户端仅保留公钥，本地无法解密已备份数据。", savePanel.URL.path];
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
    [self appendLog:[NSString stringWithFormat:@"已从系统钥匙串 (%@) 载入公钥。", svc]];
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
        [self appendLog:[NSString stringWithFormat:@"当前公钥已保存至系统钥匙串 (%@)。", svc]];
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
                [self appendLog:[NSString stringWithFormat:@"已从文件导入公钥: %@", panel.URL.path]];
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
        [self appendLog:@"已应用输入的 PEM 公钥。"];
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
    [self appendLog:[NSString stringWithFormat:@"正在测试连接 Cloudflare R2 存储桶 '%@'...", cfg.bucketName]];

    FVCloudflareUploader *uploader = [[FVCloudflareUploader alloc] initWithConfig:cfg];
    [uploader testConnectionWithCompletion:^(BOOL reachable, NSString * _Nullable message, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.testConnectionButton.enabled = YES;
            NSAlert *alert = [[NSAlert alloc] init];
            if (reachable) {
                alert.messageText = @"Cloudflare 连接成功";
                alert.informativeText = message ?: @"已成功连通 Cloudflare R2 存储桶。";
                [self appendLog:[NSString stringWithFormat:@"[OK] %@", alert.informativeText]];
            } else {
                alert.messageText = @"Cloudflare 连接失败";
                alert.informativeText = error.localizedDescription ?: message ?: @"无法访问指定存储桶。";
                [self appendLog:[NSString stringWithFormat:@"[ERROR] %@", alert.informativeText]];
            }
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
        });
    }];
}

#pragma mark - Pipeline Execution

- (void)startPipelineClicked:(id)sender {
    (void)sender;
    [self saveCurrentConfiguration];

    NSArray<NSString *> *dirs = [[FVConfigManager sharedManager] enabledDirectoryPaths];
    SecKeyRef pubKey = [FVKeyManager sharedManager].currentPublicKey;
    FVCloudflareConfig *cfConfig = [[FVConfigManager sharedManager] cloudflareConfig];

    if (dirs.count == 0) {
        [self showErrorAlert:@"请至少选择并启用一个需要备份的目录。"];
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
    self.progressLabel.stringValue = [NSString stringWithFormat:@"任务启动中 (待处理 %lu 个目录)...", (unsigned long)dirs.count];

    NSArray<NSString *> *excludes = [[FVConfigManager sharedManager] effectiveExcludePatterns];
    BOOL isInc = (self.incrementalBackupCheckbox.state == NSControlStateValueOn);
    self.currentPipeline = [[FVTaskPipeline alloc] initWithDirectoryPaths:dirs
                                                                publicKey:pubKey
                                                         cloudflareConfig:cfConfig
                                                          excludePatterns:excludes
                                                              incremental:isInc];

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
            weakSelf.progressLabel.stringValue = @"任务完成，所有目录已加密上传至 Cloudflare R2。";
            [weakSelf.directoriesTableView reloadData];
            [weakSelf updateDirectoriesStatsSummary];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"批量打包加密与上传完成";
            alert.informativeText = [NSString stringWithFormat:@"已完成 %lu 个目录的非对称加密与上传至 Cloudflare R2。\n\n最后上传远程对象:\n%@", (unsigned long)dirs.count, remoteUrl ?: @""];
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
        [self appendLog:@"用户请求取消任务..."];
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
