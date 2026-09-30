# FlareVault (macOS AppKit)

> **安全的 macOS 目录非对称加密打包与 Cloudflare R2 自动化备份工具**  
> 纯 **Objective-C + AppKit** 打造（零 Swift 依赖），遵循**单向加密安全模型（仅持有公钥，本地只能加密、绝对无法解密）**。

[![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Language-Objective--C%20%2F%20AppKit-orange.svg)](https://developer.apple.com/documentation/appkit)
[![Crypto](https://img.shields.io/badge/Encryption-RSA--OAEP%20%2B%20AES--256--CBC%20%2B%20HMAC--SHA256-green.svg)](#-安全与加密架构)
[![Storage](https://img.shields.io/badge/Storage-Cloudflare%20R2%20(S3%20SigV4)-F38020?logo=cloudflare)](https://www.cloudflare.com/products/r2/)
[![License](https://img.shields.io/badge/License-MIT-purple.svg)](LICENSE)

---

## 🌟 核心特性

- **🚀 纯原生 AppKit 架构**：无任何 Swift 运行时或三方包依赖，极小体积（原生二进制仅 ~200KB），冷启动瞬间完成，支持 macOS 12 Monterey 至最新 macOS 版本。
- **🛡️ 非对称单向加密模型（Encrypt-Only）**：
  - macOS 备份客户端**仅加载并持有非对称公钥**（`SecKeyRef` of class `kSecAttrKeyClassPublic`）。
  - **程序内无私钥、不可逆向解密**。即使备份机被盗或被入侵，攻击者也绝对无法解密任何已归档的历史数据。
- **🔑 支持从密码获取公钥（Password-Derived Public Key）**：
  - 支持输入主密码安全生成高强度非对称密钥对（2048 / 4096-bit RSA），私钥导出到离线安全介质（例如冷备 U 盘），本机仅保留公钥。
  - 支持与 macOS 钥匙串（Keychain Generic Password）双向同步与管理公钥。
  - 支持直接粘贴或载入标准 PEM 公钥（`-----BEGIN PUBLIC KEY-----`）。
- **📦 工业级流式打包与混合加密**：
  - 使用 macOS 原生 `tar + gzip` 打包，完整保留目录结构、文件权限（POSIX）、符号链接与时间戳。
  - 采用**混合信封加密体制**：动态生成一次性 256-bit AES 会话密钥与 256-bit HMAC 密钥，用 RSA-OAEP-SHA256 公钥加密信封。
  - 流式分块分段加密（1MB 缓冲），处理数十 GB 超大目录时常驻内存仍小于 15MB。
  - **Encrypt-then-MAC 强认证**：全报文计算 HMAC-SHA256，严防位翻转与密文篡改。
- **☁️ 直传 Cloudflare R2 对象存储**：
  - 原生 Objective-C 实现 AWS Signature Version 4 (SigV4) 鉴权。
  - 流式并发上传至 Cloudflare R2，实时显示传输百分比、已上传字节数及动态传输日志。
  - 支持将 Cloudflare Access Key 和 Secret Key 密文加密托管在 macOS 系统的安全钥匙串中。
- **🛠️ 跨平台解密套件**：
  - 随仓库附带原生解密命令行工具 `build/flare-vault-decrypt`（Objective-C）。
  - 附带零三方依赖的 Python 解密脚本 `Scripts/decrypt.py`（跨平台支持 Linux/Windows/macOS）。

---

## 📐 系统架构与数据流

```mermaid
flowchart TD
    subgraph Client["macOS 本地客户端 (FlareVault AppKit)"]
        Dir["📁 待备份目录"] --> Archiver["📦 FVArchiver<br/>(tar -czf 压缩)"]
        Archiver --> PlainTar["📄 临时 .tar.gz"]
        
        KeyMgr["🔑 FVKeyManager<br/>(从密码/钥匙串/PEM获取)"] --> PubKey["🔒 RSA 公钥<br/>(仅公钥，无私钥)"]
        
        SessionKey["🎲 随机 AES-256 Key<br/>+ HMAC Key"] --> RSAEnc["RSA-OAEP-SHA256"]
        PubKey --> RSAEnc
        RSAEnc --> EncKeyBlock["🔐 加密会话密钥信封"]
        
        PlainTar --> AESEnc["AES-256-CBC 流式加密"]
        SessionKey --> AESEnc
        AESEnc --> CipherPayload["密文数据流"]
        
        EncKeyBlock & CipherPayload --> HMAC["HMAC-SHA256 完整性计算"]
        HMAC --> VaultContainer["📦 .flarevault 加密容器"]
        
        VaultContainer --> SigV4["FVCloudflareUploader<br/>(AWS SigV4 签名)"]
    end
    
    subgraph Cloudflare["Cloudflare R2 云端存储"]
        SigV4 -->|HTTPS PUT Stream| R2Bucket[("☁️ Cloudflare R2 Bucket<br/>(backups/...)")]
    end
    
    subgraph Recipient["接收方 / 离线机 (具备私钥)"]
        R2Bucket -.-> Download["下载 .flarevault"]
        PrivKey["🗝️ 离线保存的 Private Key<br/>(可由密码解密)"] --> DecryptTool["flare-vault-decrypt / decrypt.py"]
        Download --> DecryptTool
        DecryptTool --> Restored["📂 完整还原目录"]
    end

    style PubKey fill:#d4edda,stroke:#28a745,stroke-width:2px;
    style PrivKey fill:#f8d7da,stroke:#dc3545,stroke-width:2px;
    style VaultContainer fill:#fff3cd,stroke:#ffc107,stroke-width:2px;
    style R2Bucket fill:#ffe5d0,stroke:#f38020,stroke-width:2px;
```

---

## 🗂️ 目录结构

```
flare-vault/
├── FlareVault/
│   ├── Main/
│   │   ├── main.m                      # 应用程序入口
│   │   ├── FVAppDelegate.h / .m        # 原生菜单与生命周期委托
│   ├── UI/
│   │   ├── FVMainWindowController.h/.m # AppKit 主窗口与全响应式界面
│   │   ├── FVDragDropView.h / .m       # 目录拖拽放置区
│   ├── Core/
│   │   ├── FVCryptoEngine.h / .m       # 非对称信封流加密核心引擎
│   │   ├── FVKeyManager.h / .m         # 密码派生与公钥钥匙串管理
│   │   ├── FVArchiver.h / .m           # 目录打包与解包
│   │   ├── FVCloudflareUploader.h / .m # Cloudflare R2 AWS SigV4 传输模块
│   │   ├── FVConfigManager.h / .m      # 本地设置与钥匙串凭证托管
│   │   ├── FVTaskPipeline.h / .m       # 打包-加密-上传流水线调度器
│   ├── Resources/
│   │   ├── Info.plist                  # macOS App Bundle 元信息
│   │   ├── AppIcon.icns                # 高清视网膜应用图标
├── Tools/
│   ├── flare-vault-decrypt.m           # 原生 C/ObjC 解密命令行工具源码
│   ├── generate_icon.m                 # 视网膜应用图标生成程序
├── Scripts/
│   ├── decrypt.py                      # 跨平台 Python 离线解密脚本
│   ├── generate_keypair.sh             # RSA 非对称密钥对生成辅助脚本
│   ├── test_e2e.sh                     # 端到端闭环验证测试套件
├── Tests/
│   ├── test_crypto.m                   # 密码引擎单元测试
│   ├── test_keymanager.m               # 密钥管理器单元测试
│   ├── test_archiver.m                 # 归档压缩单元测试
│   ├── test_uploader.m                 # Cloudflare 配置与上传测试
├── FlareVault.xcodeproj/              # 完整 Xcode 工程
├── Makefile                            # 编译构建、测试与运行指令
├── README.md                           # 项目技术文档与使用手册
└── LICENSE                             # 开源许可 (MIT)
```

---

## 🔐 安全与加密容器规范 (`.flarevault`)

生成的 `.flarevault` 文件采用二进制信封布局，格式紧凑、自包含元数据并具备抗篡改保护：

| 偏移 (Offset) | 字段名 | 长度 (Bytes) | 描述 |
| :--- | :--- | :--- | :--- |
| `0x00 - 0x03` | Magic | 4 | 魔数标识符 `FLAR` (`0x46 0x4C 0x41 0x52`) |
| `0x04` | Version | 1 | 协议版本，当前为 `0x01` |
| `0x05` | Cipher Suite | 1 | 加密算法标识，`0x01` = RSA-OAEP-SHA256 + AES-256-CBC |
| `0x06 - 0x07` | EncKeyLen | 2 (Big-Endian) | 被加密会话密钥的长度 $N$（如 2048 位密钥为 256 字节） |
| `0x08 - (0x07+N)` | EncKeyData | $N$ | RSA 公钥加密的会话包（包含 32B AES Key + 32B HMAC Key） |
| 次 16 字节 | IV | 16 | AES-256-CBC 密码学随机初始向量 |
| 次 32 字节 | HMAC Tag | 32 | HMAC-SHA256 签名（覆盖头部与所有密文数据） |
| 次 2 字节 | MetaLen | 2 (Big-Endian) | 元数据 JSON 字节长度 $M$ |
| 次 $M$ 字节 | Metadata | $M$ | 包含原始目录名、原始大小、文件数、时间戳的 JSON 字符串 |
| 剩余所有字节 | Ciphertext | 变长 | AES-256-CBC 加密后的 `tar.gz` 压缩文件流 |

---

## 🚀 快速上手

### 1. 编译构建与测试

在项目根目录下，直接使用 `make` 构建：

```bash
# 1. 编译 App 应用程序与 CLI 解密工具
make

# 2. 运行全部单元测试及端到端（打包->公钥加密->解密->SHA256校验）测试套件
make test

# 3. 启动 macOS 原生 GUI 应用程序
make run
```

编译产物位于 `build/` 目录：
- `build/FlareVault.app`：原生 macOS 应用程序。
- `build/flare-vault-decrypt`：离线解密命令行工具。

---

### 2. 界面使用指南

打开 **FlareVault** 应用后，仅需 4 步完成安全备份：

1. **选择目录**：
   - 点击 **“浏览...”** 选取，或直接**拖拽目标文件夹**到下方的拖拽区域中。
   - 应用会自动统计目录内的文件总数与未压缩总容量。
2. **装载公钥（仅加密模式）**：
   - **方式 A（从密码生成）**：输入您的主密码，点击“生成新密钥对并提取公钥”。系统会弹窗引导您将解密用的私钥另存至安全离线介质（如 USB 盘），而应用本身**仅保留公钥**。
   - **方式 B（从钥匙串获取）**：点击“从钥匙串读取公钥”，直接从 macOS Keychain 中载入已存公钥。
   - **方式 C（直接导入 PEM）**：点击“选择公钥文件...”或在文本框中粘贴 `-----BEGIN PUBLIC KEY-----` 格式的 RSA 公钥。
3. **配置 Cloudflare R2**：
   - 填写 Cloudflare **Account ID**、**Bucket Name**、**Access Key ID** 与 **Secret Access Key**。
   - 可选自定义远程前缀路径（默认为 `backups/`）。
   - 点击 **“测试 Cloudflare 连接”**，验证网络与 Bucket 权限无误。
   - 勾选“安全保存凭据到 macOS 钥匙串”，后续免去重复输入。
4. **开始打包上传**：
   - 点击 **“🚀 开始打包、加密并上传至 Cloudflare”**。
   - 实时控制台会详细输出每一步进度，完成后将给出 Cloudflare R2 远程对象 URL。

---

### 3. 数据还原与离线解密

在安全离线机器或远端灾备节点上，使用您的解密私钥解密还原备份文件：

#### 方法 A：使用原生 C/ObjC CLI 工具 (`flare-vault-decrypt`)
```bash
./build/flare-vault-decrypt \
  -k /path/to/flarevault_private_key.pem \
  -i backup_20260930_120000.flarevault \
  -o ./restored_directory/
```
若私钥设置了密码保护，加上 `-p <密码>` 即可：
```bash
./build/flare-vault-decrypt \
  -k private.pem \
  -p "MySecretVault2026!" \
  -i backup.flarevault \
  -o ./restored/
```

#### 方法 B：使用跨平台 Python 脚本 (`Scripts/decrypt.py`)
无需安装额外 pip 依赖，在任何装有 Python 3 和 openssl 的 Linux / macOS 环境下均可运行：
```bash
python3 Scripts/decrypt.py \
  --key /path/to/flarevault_private_key.pem \
  --input backup.flarevault \
  --output ./restored/
```

---

## 🛡️ 安全承诺与隔离保证

1. **绝对单向加密**：
   - 应用程序核心代码通过 Apple `Security.framework` 创建 `kSecAttrKeyClassPublic` 对象。
   - 代码中不存在任何使用本地公钥解密的逻辑（尝试解密将触发系统的底层安全拒绝 `RSAdecrypt wrong input (err -27)`）。
2. **密钥零驻留**：
   - 在从密码派生密钥对后，私钥立即导出到用户指定的文件，内存中的私钥结构被彻底清零释放。
3. **安全凭据存储**：
   - Cloudflare API 敏感私密密钥通过 macOS Keychain 服务（`kSecClassGenericPassword`）硬件级加密存储，绝不以明文形式保存在 plist 或 UserDefaults 中。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 授权许可。
