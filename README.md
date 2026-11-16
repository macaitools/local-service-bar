# LocalServiceBar（本机服务）

常驻 macOS 状态栏的本机开发服务监控工具。它会自动找出正在运行的 `npm run dev`、`pnpm dev`、`npx vite` 等前端/Node 开发服务，显示内存和 CPU 占用，并支持一键停止、重新启动。

由 AI 编程助手（Claude Code、Codex 等）在后台启动的服务也能识别。这类工具常用 `pnpm exec vite dev --port 3001` 这类写法，绕过 `package.json` 的 dev 脚本。

## 功能

- 点击状态栏图标展开面板，每秒刷新各服务整棵进程树的内存和 CPU；关闭面板后停止扫描。
- 自动检测服务进程树监听的 TCP 端口，在项目名旁显示（如 `:3001`）；点击项目名用默认浏览器打开 `http://localhost:端口`。监听了多个端口时取最小的那个，其余端口显示在鼠标悬停提示里。
- 点击启动命令或路径，在 Finder 中打开项目文件夹。
- 对服务发送 `SIGTERM` 停止，同时记下可执行文件、参数和工作目录；之后可在“已停止”列表里一键重启，或从列表移除。
- 支持登录时自动启动；如果系统要求批准，面板里可以直接跳到登录项设置。
- 不显示 Dock 图标和独立窗口；休眠唤醒、切换屏幕、菜单栏服务重启后会自动重新注册状态栏图标。

## 识别规则

只扫描当前用户运行的 `node` / `bun` 进程，满足以下任一条件才算开发服务（脚本名为 `dev` 或 `dev:*`）：

| 类型 | 示例 |
|---|---|
| 包管理器运行脚本 | `npm run dev`、`pnpm dev`、`pnpm -F web dev`、`pnpm --filter web run dev`、`pnpm -C apps/web dev:web`、`yarn dev`、`yarn workspace web dev`、`bun run dev` |
| 包管理器运行工具 | `pnpm exec vite dev`、`pnpm dlx vite`、`npm exec vite`、`npx next dev`、`pnpx vite`、`yarn dlx vite`、`bun x vite` |
| 直接运行项目里的工具 | `./node_modules/.bin/vite --port 3001`、`bunx vite`（bunx 运行后进程会变成 `node node_modules/.bin/vite`） |

工具是否算开发服务按子命令判断：

- 子命令为 `dev` 或 `serve`，如 `next dev`、`wrangler dev`、`ng serve`。
- `vite`、`next` 不带子命令时默认启动开发服务器，也算。
- 带 `build`、`preview`、`start`、`lint` 等子命令的不算。

一个服务内部再调用包管理器时（如 turbo 在每个子包里跑 `pnpm dev`，或 dev 脚本本身是 `vite dev`），只显示最外层那条，子进程的内存和 CPU 汇总到它下面。

`node server.js`、`bun --hot index.ts` 这类直接运行项目自身脚本的进程，无法判断是否为开发服务，不会识别。

## 下载安装

每次推送到 `main`，GitHub Actions 都会自动构建，并更新 [Releases](https://github.com/macaitools/local-service-bar/releases/latest) 中的 `LocalServiceBar.zip`（同时支持 Apple Silicon 和 Intel）。

1. 下载并解压 `LocalServiceBar.zip`，把 `LocalServiceBar.app` 拖到“应用程序”文件夹。
2. 安装包使用 ad-hoc 签名，未经 Apple 公证。首次打开如果提示“已损坏”或“无法验证开发者”，先执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/LocalServiceBar.app
   ```

3. 打开后菜单栏会出现图标。最低系统要求为 macOS 13。

## 从源码构建

**使用 Xcode**：打开 `LocalServiceBar.xcodeproj`，运行 `LocalServiceBar` target。

**命令行（与 CI 相同）**：

```bash
xcodebuild -project LocalServiceBar.xcodeproj -target LocalServiceBar -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  SYMROOT="$PWD/build" build
```

产物位于 `build/Release/LocalServiceBar.app`。

**只有 Command Line Tools、没有 Xcode 时**：

```bash
mkdir -p build/LocalServiceBar.app/Contents/MacOS
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  LocalServiceBar/*.swift -o build/LocalServiceBar.app/Contents/MacOS/LocalServiceBar
sed -e 's/$(EXECUTABLE_NAME)/LocalServiceBar/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.localservicebar.app/' \
    LocalServiceBar/Info.plist > build/LocalServiceBar.app/Contents/Info.plist
codesign --force --sign - build/LocalServiceBar.app
```

## 实现说明

- **进程信息**：用 `proc_listpids`、`proc_pidinfo`、`proc_pid_rusage` 和 `sysctl(KERN_PROCARGS2)` 读取进程列表、父子关系、内存占用（`phys_footprint`）、CPU 时间、启动参数和工作目录；监听端口通过 `PROC_PIDLISTFDS` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` 读取 LISTEN 状态的 TCP socket。不依赖 `ps` 或 `lsof`。
- **npm / npx 的参数**：npm 会改写 `process.title`，内核里的 argv 只剩 `npm run dev` 这样的标题，其余参数为空。扫描时按标题还原成 `node <node 同级 lib>/node_modules/npm/bin/npm-cli.js run dev`，识别和重启都按它处理。还原时按空格拆分标题，参数本身带空格时重启可能不准确。
- **npm 全局安装的 bun**：`bun.exe` 与 `bunx.exe` 是硬链接，内核返回的路径可能是其中任意一个，统一按同目录下的 `bun.exe` 处理。
- **重启时的 PATH**：重启服务不会恢复原进程的环境变量，项目需要的变量应由项目自己的 `.env` 加载逻辑提供。登录自启时 launchd 提供的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，`#!/usr/bin/env node` 会找不到 node，因此重启时会把 node / bun 所在目录补到 PATH 最前面。
- **停止前复核**：发送 `SIGTERM` 前会重新确认该 PID 的可执行文件、参数和工作目录没有变化，避免 PID 被复用后误杀其他进程。
- **状态栏日志**：写入系统统一日志，子系统为 `com.localservicebar.app`、类别为 `StatusItem`。日志是 `info` 级别，默认不落盘，需要时实时查看：

  ```bash
  log stream --info --predicate 'subsystem == "com.localservicebar.app"'
  ```

## 目录结构

```
LocalServiceBar/
  LocalServiceBarApp.swift   # 应用入口、状态栏按钮与面板
  ServicePopoverView.swift   # 面板界面
  ServiceMonitor.swift       # 扫描调度、停止/重启、登录项、停止记录
  ProcessScanner.swift       # 进程扫描与开发服务识别规则
.github/workflows/build.yml  # 自动构建并发布到 Releases
```
