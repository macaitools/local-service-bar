import Darwin
import Foundation

enum DevServiceCommand {
    /// 工具后跟这些子命令视为开发服务，如 `next dev`、`ng serve`。
    private static let devSubcommands: Set<String> = ["dev", "serve"]
    /// 不带子命令时默认就是开发服务器的工具，如 `vite --port 3001`。
    private static let defaultDevTools: Set<String> = ["vite", "next"]
    private static let nonDevSubcommands: Set<String> = [
        "build", "preview", "optimize", "start", "lint", "export", "info", "telemetry",
    ]
    private static let nodeValueOptions: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "--env-file",
    ]
    private static let toolRunnerValueOptions: Set<String> = ["-p", "--package"]

    /// 返回用于展示的命令；nil 表示不是开发服务。
    static func manager(executablePath: String, arguments: [String]) -> String? {
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()

        if executable == "bun" || executable == "bun.exe" {
            return packageManagerCommand(
                "bun", arguments,
                valueOptions: ["--cwd", "--filter", "-F", "--config"],
                execCommands: ["x"]
            )
        }

        guard executable == "node" || executable == "nodejs" else { return nil }
        guard let scriptIndex = positionalIndices(arguments, valueOptions: nodeValueOptions).first else {
            return nil
        }

        let script = arguments[scriptIndex]
        let entryPoint = URL(fileURLWithPath: script).lastPathComponent.lowercased()
        let rest = Array(arguments[(scriptIndex + 1)...])

        switch entryPoint {
        case "npm-cli.js", "npm.js", "npm":
            return packageManagerCommand(
                "npm", rest,
                valueOptions: ["-w", "--workspace", "--prefix", "-C"],
                execCommands: ["exec", "x"]
            )
        case "npx-cli.js", "npx":
            return toolInvocation(rest).map { "npx \($0)" }
        case "pnpm.cjs", "pnpm.js", "pnpm.mjs", "pnpm":
            return packageManagerCommand(
                "pnpm", rest,
                valueOptions: ["-F", "--filter", "--filter-prod", "-C", "--dir"],
                execCommands: ["exec", "dlx"]
            )
        case "pnpx.cjs", "pnpx.js", "pnpx":
            return toolInvocation(rest).map { "pnpx \($0)" }
        case "yarn.js", "yarn.cjs", "yarn":
            return packageManagerCommand("yarn", rest, valueOptions: ["--cwd"], execCommands: ["exec", "dlx"])
        default:
            // Yarn Berry 的 .yarn/releases/yarn-4.x.cjs
            if entryPoint.hasPrefix("yarn-"), entryPoint.hasSuffix(".cjs") {
                return packageManagerCommand("yarn", rest, valueOptions: ["--cwd"], execCommands: ["exec", "dlx"])
            }
            // 直接运行项目里的工具：./node_modules/.bin/vite、bunx 替换后的进程等
            if script.contains("node_modules/") {
                return toolCommand(directToolName(script), rest)
            }
            return nil
        }
    }

    /// 包管理器命令：`pnpm -F web dev`、`yarn workspace web run dev:web`、`npm exec vite` 等。
    private static func packageManagerCommand(
        _ name: String,
        _ arguments: [String],
        valueOptions: Set<String>,
        execCommands: Set<String>
    ) -> String? {
        let positions = positionalIndices(arguments, valueOptions: valueOptions)
        guard let first = positions.first else { return nil }

        if execCommands.contains(arguments[first]) {
            return toolInvocation(Array(arguments[(first + 1)...]))
                .map { "\(name) \(arguments[first]) \($0)" }
        }

        var cursor = 0
        if name == "yarn", arguments[first] == "workspace" { cursor = 2 }
        let usesRun = cursor < positions.count && ["run", "run-script"].contains(arguments[positions[cursor]])
        if usesRun { cursor += 1 }
        guard cursor < positions.count else { return nil }

        let script = arguments[positions[cursor]]
        guard script == "dev" || script.hasPrefix("dev:") else { return nil }
        return usesRun ? "\(name) run \(script)" : "\(name) \(script)"
    }

    /// `vite dev`、`-y next dev`、`-p vite vite --port 3001` 这类“工具 + 参数”。
    private static func toolInvocation(_ arguments: [String]) -> String? {
        guard let toolIndex = positionalIndices(arguments, valueOptions: toolRunnerValueOptions).first else {
            return nil
        }
        return toolCommand(packageToolName(arguments[toolIndex]), Array(arguments[(toolIndex + 1)...]))
    }

    private static func toolCommand(_ tool: String, _ arguments: [String]) -> String? {
        let subcommand = arguments.first { !$0.hasPrefix("-") }
        if let subcommand, devSubcommands.contains(subcommand) {
            return "\(tool) \(subcommand)"
        }
        if defaultDevTools.contains(tool), !(subcommand.map(nonDevSubcommands.contains) ?? false) {
            return tool
        }
        return nil
    }

    /// `vite@latest` → vite，`@scope/cli@1` → cli。
    private static func packageToolName(_ value: String) -> String {
        let base = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        guard let at = base.dropFirst().firstIndex(of: "@") else { return base }
        return String(base[..<at])
    }

    /// `node_modules/.bin/vite` → vite，`node_modules/vite/bin/vite.js` → vite。
    private static func directToolName(_ script: String) -> String {
        let components = script.split(separator: "/").map(String.init)
        if let binIndex = components.lastIndex(of: ".bin"),
           binIndex + 1 < components.count,
           components[binIndex + 1] != ".." {
            return components[binIndex + 1].lowercased()
        }
        return URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent.lowercased()
    }

    /// 去掉选项及其取值后剩下的位置参数下标；`--` 之后全部算位置参数。
    private static func positionalIndices(_ arguments: [String], valueOptions: Set<String>) -> [Int] {
        var result: [Int] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                result.append(contentsOf: (index + 1)..<arguments.count)
                break
            }
            if argument.hasPrefix("-") {
                index += valueOptions.contains(argument) ? 2 : 1
                continue
            }
            result.append(index)
            index += 1
        }
        return result
    }
}

struct ServiceProcess: Identifiable, Hashable {
    let pid: pid_t
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
    let residentBytes: UInt64
    let cpuPercent: Double
    let processCount: Int

    var id: pid_t { pid }
    var name: String {
        let directoryName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        if !directoryName.isEmpty, directoryName != "/" {
            return directoryName
        }

        if let script = arguments.first(where: { !$0.hasPrefix("-") }) {
            return URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent
        }
        return "开发服务 \(pid)"
    }

    var commandLine: String {
        DevServiceCommand.manager(executablePath: executablePath, arguments: arguments)
            ?? ([URL(fileURLWithPath: executablePath).lastPathComponent] + arguments).joined(separator: " ")
    }

    func hasSameLaunchConfiguration(as other: ServiceProcess) -> Bool {
        executablePath == other.executablePath
            && arguments == other.arguments
            && workingDirectory == other.workingDirectory
    }
}

final class ProcessScanner {
    private struct CPUSample {
        let totalNanoseconds: UInt64
        let sampledAt: UInt64
        let processStart: UInt64
    }

    private struct ProcessIdentity {
        let parentPID: pid_t
        let startToken: UInt64
    }

    private var previousSamples: [pid_t: CPUSample] = [:]

    func reset() {
        previousSamples.removeAll(keepingCapacity: false)
    }

    func scan() -> [ServiceProcess] {
        let processIDs = currentUserProcessIDs()

        var identities: [pid_t: ProcessIdentity] = [:]
        for pid in processIDs where pid > 1 && pid != getpid() {
            if let identity = processIdentity(for: pid) {
                identities[pid] = identity
            }
        }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for (pid, identity) in identities {
            childrenByParent[identity.parentPID, default: []].append(pid)
        }

        let launchers = processIDs.compactMap { pid -> ServiceProcess? in
            guard pid > 1, pid != getpid(),
                  let executablePath = executablePath(for: pid),
                  Self.isSupportedRuntime(executablePath),
                  let arguments = arguments(for: pid),
                  DevServiceCommand.manager(executablePath: executablePath, arguments: arguments) != nil,
                  let workingDirectory = workingDirectory(for: pid) else {
                return nil
            }

            return ServiceProcess(
                pid: pid,
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory,
                residentBytes: 0,
                cpuPercent: 0,
                processCount: 1
            )
        }

        // 脚本里再调包管理器（turbo、`"dev": "vite dev"` 的子进程等）时只保留最外层，避免重复计数。
        let launcherPIDs = Set(launchers.map(\.pid))
        let rootLaunchers = launchers.filter { launcher in
            var visited: Set<pid_t> = [launcher.pid]
            var current = identities[launcher.pid]?.parentPID
            while let pid = current, pid > 1, visited.insert(pid).inserted {
                if launcherPIDs.contains(pid) { return false }
                current = identities[pid]?.parentPID
            }
            return true
        }

        var currentSamples: [pid_t: CPUSample] = [:]

        let processes = rootLaunchers.map { launcher -> ServiceProcess in
            let family = descendants(of: launcher.pid, childrenByParent: childrenByParent)
            var residentBytes: UInt64 = 0
            var cpuPercent = 0.0

            for memberPID in family {
                guard let identity = identities[memberPID],
                      let usage = resourceUsage(for: memberPID) else {
                    continue
                }

                residentBytes &+= usage.ri_phys_footprint
                let totalCPU = usage.ri_user_time &+ usage.ri_system_time
                let sampledAt = DispatchTime.now().uptimeNanoseconds
                currentSamples[memberPID] = CPUSample(
                    totalNanoseconds: totalCPU,
                    sampledAt: sampledAt,
                    processStart: identity.startToken
                )

                if let previous = previousSamples[memberPID],
                   previous.processStart == identity.startToken,
                   totalCPU >= previous.totalNanoseconds,
                   sampledAt > previous.sampledAt {
                    let elapsed = sampledAt - previous.sampledAt
                    cpuPercent += Double(totalCPU - previous.totalNanoseconds) / Double(elapsed) * 100
                }
            }

            return ServiceProcess(
                pid: launcher.pid,
                executablePath: launcher.executablePath,
                arguments: launcher.arguments,
                workingDirectory: launcher.workingDirectory,
                residentBytes: residentBytes,
                cpuPercent: cpuPercent,
                processCount: family.count
            )
        }

        previousSamples = currentSamples
        return processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func stillMatches(_ process: ServiceProcess) -> Bool {
        guard let executablePath = executablePath(for: process.pid),
              isSupportedRuntime(executablePath),
              let arguments = arguments(for: process.pid),
              DevServiceCommand.manager(executablePath: executablePath, arguments: arguments) != nil,
              let workingDirectory = workingDirectory(for: process.pid) else {
            return false
        }

        return executablePath == process.executablePath
            && arguments == process.arguments
            && workingDirectory == process.workingDirectory
    }

    private func currentUserProcessIDs() -> [pid_t] {
        let processType = UInt32(PROC_UID_ONLY)
        let userID = UInt32(getuid())
        let requiredBytes = proc_listpids(processType, userID, nil, 0)
        guard requiredBytes > 0 else { return [] }

        var processIDs = Array(repeating: pid_t(0), count: Int(requiredBytes) / MemoryLayout<pid_t>.stride + 8)
        let actualBytes = processIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                processType,
                userID,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard actualBytes > 0 else { return [] }
        return processIDs.prefix(Int(actualBytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    private func processIdentity(for pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard bytesRead == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }

        let startToken = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        return ProcessIdentity(parentPID: pid_t(info.pbi_ppid), startToken: startToken)
    }

    private func resourceUsage(for pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { buffer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
        }
        return result == 0 ? info : nil
    }

    private func descendants(of rootPID: pid_t, childrenByParent: [pid_t: [pid_t]]) -> [pid_t] {
        var result = [rootPID]
        var visited: Set<pid_t> = [rootPID]
        var cursor = 0

        while cursor < result.count {
            for childPID in childrenByParent[result[cursor]] ?? [] where visited.insert(childPID).inserted {
                result.append(childPID)
            }
            cursor += 1
        }

        return result
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let bytesWritten = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard bytesWritten > 0 else { return nil }
        let path = String(cString: buffer)

        // npm 装的 bun.exe 与 bunx.exe 是硬链接，内核可能返回任意一个名字；统一成 bun，
        // 否则 `bun run dev` 会被误判，重启时也会变成 `bunx run dev`。
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        if name == "bunx" || name == "bunx.exe" {
            let bunPath = url.deletingLastPathComponent()
                .appendingPathComponent(name == "bunx" ? "bun" : "bun.exe").path
            if FileManager.default.fileExists(atPath: bunPath) { return bunPath }
        }
        return path
    }

    private func executablePath(for pid: pid_t) -> String? {
        Self.executablePath(for: pid)
    }

    private static func isSupportedRuntime(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        // npm 全局安装的 bun 实际可执行文件是 node_modules/bun/bin/bun.exe
        return name == "node" || name == "nodejs" || name == "node.exe" || name == "bun" || name == "bun.exe"
    }

    private static func workingDirectory(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        }
        guard bytesRead == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }

        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let path = String(cString: baseAddress)
            return path.isEmpty ? nil : path
        }
    }

    private func workingDirectory(for pid: pid_t) -> String? {
        Self.workingDirectory(for: pid)
    }

    private static func arguments(for pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var requiredSize = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), nil, &requiredSize, nil, 0)
        }
        guard sizeResult == 0, requiredSize > MemoryLayout<Int32>.size else { return nil }

        var bytes = [UInt8](repeating: 0, count: requiredSize)
        let readResult = bytes.withUnsafeMutableBytes { output in
            mib.withUnsafeMutableBufferPointer { pointer in
                sysctl(pointer.baseAddress, u_int(pointer.count), output.baseAddress, &requiredSize, nil, 0)
            }
        }
        guard readResult == 0, requiredSize > MemoryLayout<Int32>.size else { return nil }

        let limit = min(requiredSize, bytes.count)
        let argc = bytes.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }
        guard argc > 0 else { return [] }

        var cursor = MemoryLayout<Int32>.size
        while cursor < limit, bytes[cursor] != 0 { cursor += 1 }
        while cursor < limit, bytes[cursor] == 0 { cursor += 1 }

        var parsed: [String] = []
        for _ in 0..<Int(argc) {
            guard cursor < limit else { break }
            let start = cursor
            while cursor < limit, bytes[cursor] != 0 { cursor += 1 }
            parsed.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }

        // npm/npx 会改写 process.title，argv 区域只剩 "npm run dev" 这样的标题，其余参数为空。
        // 这里按标题还原成 npm-cli.js 的参数，识别和重启都按它走。
        if let title = parsed.first, title.hasPrefix("npm "),
           parsed.dropFirst().allSatisfy(\.isEmpty),
           let executablePath = executablePath(for: pid) {
            let npmCLI = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .appendingPathComponent("../lib/node_modules/npm/bin/npm-cli.js")
                .standardizedFileURL.path
            return [npmCLI] + title.split(separator: " ").dropFirst().map(String.init)
        }

        // kern.procargs2 also contains argv[0]; Process.executableURL supplies that path on restart.
        return Array(parsed.dropFirst())
    }

    private func arguments(for pid: pid_t) -> [String]? {
        Self.arguments(for: pid)
    }
}
