import Darwin
import Combine
import Foundation
import ServiceManagement

struct TrackedService: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
    let originalPID: pid_t

    var commandLine: String {
        DevServiceCommand.manager(executablePath: executablePath, arguments: arguments)
            ?? ([URL(fileURLWithPath: executablePath).lastPathComponent] + arguments).joined(separator: " ")
    }

    var isDevService: Bool {
        DevServiceCommand.manager(executablePath: executablePath, arguments: arguments) != nil
    }

    init(process: ServiceProcess) {
        id = UUID()
        name = process.name
        executablePath = process.executablePath
        arguments = process.arguments
        workingDirectory = process.workingDirectory
        originalPID = process.pid
    }

    func hasSameConfiguration(as process: ServiceProcess) -> Bool {
        executablePath == process.executablePath
            && arguments == process.arguments
            && workingDirectory == process.workingDirectory
    }
}

final class ServiceMonitor: ObservableObject {
    @Published private(set) var runningProcesses: [ServiceProcess] = []
    @Published private(set) var lastKnownRunningCount = 0
    @Published private(set) var trackedServices: [TrackedService] = []
    @Published private(set) var processRecordIDs: [pid_t: UUID] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var launchAtLoginStatus: SMAppService.Status
    @Published var message: String?

    private let scanner = ProcessScanner()
    private let scanQueue = DispatchQueue(label: "LocalServiceBar.process-scan", qos: .utility)
    private var isScanning = false
    private var isMonitoring = false
    private var hasCompletedScan = false
    private var monitoringGeneration = 0
    private var refreshTimer: DispatchSourceTimer?

    var stoppedServices: [TrackedService] {
        let runningIDs = Set(processRecordIDs.values)
        return trackedServices.filter { !runningIDs.contains($0.id) }
    }

    var launchesAtLogin: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var needsLoginApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    init() {
        launchAtLoginStatus = SMAppService.mainApp.status
        loadTrackedServices()
    }

    func startMonitoring() {
        refreshLaunchAtLoginStatus()
        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringGeneration &+= 1
        refresh()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        refreshTimer = timer
        timer.resume()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }

            refreshLaunchAtLoginStatus()
            switch launchAtLoginStatus {
            case .enabled:
                message = enabled ? "已开启开机启动" : "已关闭开机启动"
            case .requiresApproval:
                message = enabled ? "已登记开机启动，请在系统设置中允许" : "开机启动尚未关闭"
            case .notRegistered:
                message = enabled ? "开机启动未启用，请重试" : "已关闭开机启动"
            case .notFound:
                message = "开机启动项不可用"
            @unknown default:
                message = "无法确认开机启动状态"
            }
        } catch {
            launchAtLoginStatus = service.status
            message = "开机启动设置失败：\(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitoringGeneration &+= 1
        refreshTimer?.cancel()
        refreshTimer = nil
        runningProcesses = []
        processRecordIDs = [:]
        isLoading = false
        hasCompletedScan = false
        message = nil

        // Keep scanner state confined to its serial queue, after any in-flight scan.
        scanQueue.async { [scanner = self.scanner] in
            scanner.reset()
        }
    }

    func refresh() {
        guard isMonitoring, !isScanning else { return }
        isScanning = true
        if !hasCompletedScan {
            isLoading = true
        }
        let generation = monitoringGeneration
        scanQueue.async { [weak self] in
            guard let self else { return }
            let processes = self.scanner.scan()
            DispatchQueue.main.async {
                self.isScanning = false
                guard self.isMonitoring, self.monitoringGeneration == generation else { return }
                self.runningProcesses = processes
                self.lastKnownRunningCount = processes.count
                self.processRecordIDs = self.mapTrackedServices(to: processes)
                self.hasCompletedScan = true
                self.isLoading = false
            }
        }
    }

    func name(for process: ServiceProcess) -> String {
        guard let recordID = processRecordIDs[process.pid],
              let record = trackedServices.first(where: { $0.id == recordID }) else {
            return process.name
        }
        return record.name
    }

    func stop(_ process: ServiceProcess) {
        saveForRestart(process)
        message = "正在停止 \(name(for: process))…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Int32
            let errorCode: Int32
            if ProcessScanner.stillMatches(process) {
                result = kill(process.pid, SIGTERM)
                errorCode = result == 0 ? 0 : errno
            } else {
                result = -1
                errorCode = ESRCH
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if result == 0 {
                    self.message = "已发送停止信号"
                } else if errorCode == ESRCH {
                    self.message = "服务已退出"
                } else {
                    self.message = String(cString: strerror(errorCode))
                }
                self.refresh()
            }
        }
    }

    func start(_ service: TrackedService) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: service.executablePath)
        process.arguments = service.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: service.workingDirectory, isDirectory: true)

        // 登录自启时 launchd 只给 /usr/bin:/bin:/usr/sbin:/sbin，bin 脚本的 `#!/usr/bin/env node`
        // 会找不到 node；把运行时所在目录（nvm 下同时有 npm/pnpm）补到 PATH 前面。
        var environment = ProcessInfo.processInfo.environment
        let runtimeDirectory = URL(fileURLWithPath: service.executablePath).deletingLastPathComponent().path
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").contains(Substring(runtimeDirectory)) {
            environment["PATH"] = "\(runtimeDirectory):\(path)"
        }
        process.environment = environment

        do {
            try process.run()
            message = "已启动 \(service.name)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refresh()
            }
        } catch {
            message = "启动失败：\(error.localizedDescription)"
        }
    }

    func forget(_ service: TrackedService) {
        trackedServices.removeAll { $0.id == service.id }
        saveTrackedServices()
        message = "已从监控列表移除 \(service.name)"
    }

    private func saveForRestart(_ process: ServiceProcess) {
        if let recordID = processRecordIDs[process.pid],
           let index = trackedServices.firstIndex(where: { $0.id == recordID }) {
            trackedServices[index].name = process.name
        } else {
            trackedServices.append(TrackedService(process: process))
        }
        saveTrackedServices()
    }

    private func mapTrackedServices(to processes: [ServiceProcess]) -> [pid_t: UUID] {
        var available = trackedServices
        var result: [pid_t: UUID] = [:]

        for process in processes {
            let index = available.firstIndex {
                $0.originalPID == process.pid && $0.hasSameConfiguration(as: process)
            } ?? available.firstIndex { $0.hasSameConfiguration(as: process) }

            guard let index else { continue }
            result[process.pid] = available[index].id
            available.remove(at: index)
        }
        return result
    }

    private func loadTrackedServices() {
        guard let data = UserDefaults.standard.data(forKey: "tracked-services"),
              let services = try? JSONDecoder().decode([TrackedService].self, from: data) else {
            return
        }
        trackedServices = services.filter(\.isDevService)
        if trackedServices.count != services.count {
            saveTrackedServices()
        }
    }

    private func saveTrackedServices() {
        guard let data = try? JSONEncoder().encode(trackedServices) else { return }
        UserDefaults.standard.set(data, forKey: "tracked-services")
    }
}
