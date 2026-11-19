# IoTCenter iOS Shell

这个目录现在是一个原生 iOS 壳工程，用来把前端 `www` 打包成本地独立 App。

## 前端放置位置

把你的前端构建产物整体拷贝到：

`/Users/shuaijq/iotcenter_ios/www/`

要求：

- 入口文件必须是 `www/index.html`
- 其他资源文件保持原始相对路径
- 直接覆盖当前 `www/` 目录即可

## 运行方式

1. 打开 `IoTCenter.xcodeproj`
2. 选择 `IoTCenter` target
3. 修改 `Bundle Identifier`
4. 选择你的开发者签名团队
5. 运行到模拟器或真机

## 构建与打包

- 没有 Xcode 的机器（例如当前这台 Linux）可以跑预检：`python3 scripts/preflight.py`
- 有 Xcode 的 Mac 上一条命令归档/导出：`scripts/build-ios.sh`（参数见 `--help`）
- 从 Linux 触发远端 Mac 编译：`scripts/build-on-mac.sh user@mac`
- CI（GitHub Actions，macOS runner）：`.github/workflows/ios-build.yml`

完整说明（含签名、版本号、常见报错）见 [BUILD.md](BUILD.md)。

## 当前实现

- App 使用 `WKWebView` 加载包内 `www`
- `www` 作为整个文件夹被复制进 App bundle
- 对于没有文件后缀的前端路由，会自动回退到 `index.html`，适合大多数 SPA

## 需要注意

- 如果前端使用了浏览器特性里只支持 `http/https` 的能力，可能还需要针对 iOS WebView 做额外适配
- 默认 bundle id 是 `com.example.iotcenter`，上线前请改成你自己的
