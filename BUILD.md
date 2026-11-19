# 编译与打包说明（IoTCenter / WiseGreenHouser）

## 结论先行

**在这台 Linux 机器上不能直接编译出 iOS App。** iOS 编译依赖 macOS + Xcode + iOS SDK，
三者都不存在（本机是 Fedora，`xcodebuild`、`swift`、`swiftc` 全都没有；
即使单独装 Swift for Linux，也没有 UIKit / WebKit，编译不了这套壳工程）。

但"编译工作"可以在这里闭环，有两条路：

| 方案 | 需要什么 | 适合场景 |
| --- | --- | --- |
| A. 本机预检 + 远端 Mac 编译 | 一台能 SSH 的 Mac（已装 Xcode） | 想继续在这台机器上敲命令 |
| B. 本机预检 + GitHub Actions | 一个 GitHub 仓库；签名上传另需证书 secrets | 没有常开的 Mac（**当前选择**） |
| C. 直接在有 Xcode 的 Mac 上跑 | 任意 Mac | 最简单，改完代码立刻打 |

方案 A/C 用的是同一套脚本 `scripts/build-ios.sh`，只是 A 通过 `scripts/build-on-mac.sh` 远程调用。

## 本机现在就能做的事

```bash
python3 scripts/preflight.py
```

这是不依赖 Xcode 的工程预检，覆盖 18 项：pbxproj 可解析、文件引用齐全、
Swift 源文件都进了 Sources、www 文件夹引用在 Resources 里、Info.plist 合法且必需键齐全、
ATS 放行、AppIcon 18 张图标尺寸与不透明性、www/index.html 及其引用资源、
版本号、括号配对等。

当前工程跑出来：**0 失败，2 警告**

- ⚠️ 缺 `CFBundleDisplayName`：桌面图标下会显示 `IoTCenter`，想显示中文名需要加这个键。
- ⚠️ 版本仍是 `1.3.1 (7)`，和上一次上传 App Store 的组合相同。重新上传前必须把
  `CURRENT_PROJECT_VERSION` 加到 8（或递增），否则 App Store Connect 会拒绝。

另外确认过远端热更新包：`http://yunxue.online/version/web/www.zip` 返回 200，
11,060,929 字节，zip 内是 `www/index.html` 结构，无 `..` 等危险路径，和 App 里
`ZipArchiveExtractor` + `resolveExtractedWWWRootURL` 的预期一致。

## 方案 B：GitHub Actions（当前选择）

`.github/workflows/ios-build.yml` 里有三个 job：

| job | runner | 作用 | 需要证书 |
| --- | --- | --- | --- |
| `preflight` | ubuntu-latest | 跑 `scripts/preflight.py`，几秒 | 否 |
| `build-unsigned` | macos-15 | 先模拟器编译，再不签名归档，校验 app 内 `www/index.html`、版本号、架构，上传 `.xcarchive` | 否 |
| `build-signed` | macos-15 | 导入证书/描述文件，归档导出 ipa，可上传 App Store Connect | 是 |

`build-signed` 只在你手动 Run workflow 并勾选 `signed` 时执行；`upload` 勾选后才上传。

### 第一次把代码推上仓库

这台机器上没有装 `git`（`which git` 为空），有两条路：

1. **在 Mac 上推**（推荐，Mac 自带 git）。先把本机新增的这几个文件拷过去：
   `scripts/`、`.github/`、`BUILD.md`、`.gitignore`，然后：

   ```bash
   cd iotcenter_ios          # 含 IoTCenter.xcodeproj 的这一层
   git init -b main
   git add -A
   git commit -m "iOS 壳工程 + 构建脚本 + CI"
   gh repo create iotcenter-ios --private --source=. --push
   # 没有 gh 的话：
   git remote add origin git@github.com:<你的账号>/iotcenter-ios.git
   git push -u origin main
   ```

2. **在这台机器上装 git**（需要 root）：`sudo dnf install -y git`，再执行上面的 `git init ...`，
   `git push` 时需要 GitHub 的 token 或 SSH key。

`.gitignore` 已经排除了 `build/`、`DerivedData/`、`www.backup-*/`、`*.xcarchive`、`*.ipa`，
推之前 `git status` 扫一眼，确认没有把 30 MB 的备份目录或历史 archive 提交进去。

### 签名 secrets（`build-signed` job）

| Secret | 内容 | 从哪来 |
| --- | --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 发布证书 `.p12` 的 base64 | Xcode → Settings → Accounts → Manage Certificates → 导出；`base64 -i Cert.p12 \| pbcopy` |
| `P12_PASSWORD` | 导出 p12 时设的密码 | 导出时自己设 |
| `KEYCHAIN_PASSWORD` | 任意强密码，仅供 CI 临时 keychain | 自己生成 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 | developer.apple.com → Profiles 下载；`base64 -i xxx.mobileprovision \| pbcopy` |
| `PROFILE_NAME` | 描述文件名称 | `security cms -D -i xxx.mobileprovision \| plutil -extract Name raw -` |
| `SIGNING_IDENTITY` | 例如 `Apple Distribution: sean shuai (E6PHPA54WZ)` | `security find-identity -v -p codesigning` |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_CONTENT` | App Store Connect API Key（`.p8` 内容） | App Store Connect → 用户和访问 → 集成 → App Store Connect API（`.p8` 只能下载一次） |

`build-signed` 用**手动签名**（`PROFILE_NAME` 非空时脚本自动切换），比自动签名在 CI 上更稳。
若 secrets 没配全，job 会在"检查签名配置"一步直接报错退出，不会白跑一次归档。

> 私有仓库的 macOS runner 按 10 倍时长计费（免费额度 2000 分钟/月，macOS 折合 200 分钟），
> 一次归档大约 1–3 分钟，够用；`build-unsigned` 每次 push 都会跑，介意可以改成只手动触发。

## 方案 A：远端 Mac 编译（从这台机器一条命令）

前提：Mac 上装好 Xcode，`xcode-select -p` 指向它，并已配置 SSH 免密登录。

```bash
ssh-copy-id shuaijq@<mac-ip>

# 只验证能不能编译（模拟器，不签名，最快）
scripts/build-on-mac.sh shuaijq@<mac-ip> --simulator

# 正式出 App Store 包
scripts/build-on-mac.sh shuaijq@<mac-ip> \
  --method app-store-connect --version 1.3.2 --build-number 8
```

脚本会 rsync 同步源码（排除 `build/`、`www.backup-*`、截图等）、ssh 执行
`scripts/build-ios.sh`、再把 `build/` 下的产物取回本地 `build/remote/`。

## 方案 C：任意 Mac 本地

```bash
rsync -az --exclude build --exclude 'www.backup-*' ./ user@mac:~/iotcenter_ios/
ssh user@mac 'cd ~/iotcenter_ios && ./scripts/build-ios.sh'
```

## `scripts/build-ios.sh` 参数

| 参数 | 说明 |
| --- | --- |
| `--simulator` | Debug 编译 iOS 模拟器版本，不签名，最快验证代码 |
| `--unsigned` | Release 归档但不签名，验证编译与打包链路 |
| `--no-export` | 只 archive，不导出 ipa |
| `--method <m>` | `app-store-connect`（默认）/ `release-testing` / `ad-hoc` / `development` / `enterprise` |
| `--upload` | 导出后 `xcrun altool` 上传，需要 `ASC_KEY_ID`、`ASC_ISSUER_ID` 和对应 `.p8` |
| `--version <x.y.z>` | 覆盖 `MARKETING_VERSION` |
| `--build-number <n>` | 覆盖 `CURRENT_PROJECT_VERSION`（重复上传前必须递增） |
| `--team <TEAM_ID>` | 覆盖开发团队，默认 `E6PHPA54WZ` |
| `--output <dir>` | 产物目录，默认 `build/` |
| `--no-preflight` | 跳过预检 |

环境变量 `PROFILE_NAME` / `SIGNING_IDENTITY` 非空时切换为手动签名，`BUNDLE_ID` 可覆盖从
pbxproj 里读到的 bundle id。

产物：`build/IoTCenter-<版本>-<构建号>-<时间戳>.xcarchive`、
`build/export-<method>-<时间戳>/*.ipa`，以及同名 `.log` 构建日志。

## 打包相关的几个事实

- Bundle ID：`com.cloudyboots.wisegreenhouser`，开发团队 `E6PHPA54WZ`（与历史 archive 一致）。
- 最低系统：iOS 16.0；工程由 Xcode 26.4 创建（`objectVersion = 60`，兼容 Xcode 15+）。
- `www/` 以"文件夹引用"整体进包，当前 2,622 个文件、27 MB，App 体积主要是它。
- 首次归档大部分时间花在拷贝 `www` 和编译资源上，通常 1–3 分钟；模拟器编译约 30–60 秒。
- 版本号 / 构建号在 `IoTCenter.xcodeproj/project.pbxproj` 的 Release 配置里，
  也可以用 `--version` / `--build-number` 临时覆盖，不必改工程文件。

## 常见报错

| 报错 | 原因 / 处理 |
| --- | --- |
| `No signing certificate "iOS Development" found` | Mac 上 Xcode 未登录开发者账号，或 team 不对；CI 需导入 p12 |
| `App Store Connect: bundle version must be higher` | `--build-number` 没递增 |
| `xcodebuild: error: Unable to find a destination` | 模拟器 runtime 未安装，改用 `--unsigned` 归档 |
| `找不到 IoTCenter.xcodeproj` | 在工程根目录（含 `.xcodeproj` 的那层）执行 |
| `command not found: xcodebuild` | 未装 Xcode 或 `xcode-select` 没指向 Xcode.app |
| `exportArchive: No signing certificate "iOS Distribution" found` | CI 上 `SIGNING_IDENTITY` 与导入的 p12 不匹配 |

> 脚本刻意兼容 macOS 自带的 bash 3.2（空数组展开、`find` 不带 `-maxdepth`），
> 在 zsh / bash 5 下同样可用。
