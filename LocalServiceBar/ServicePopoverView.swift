import AppKit
import SwiftUI

struct ServicePopoverView: View {
    @ObservedObject var monitor: ServiceMonitor

    var body: some View {
        VStack(spacing: 0) {
            header

            List {
                Section("开发服务 · \(monitor.runningProcesses.count)") {
                    if monitor.runningProcesses.isEmpty {
                        if monitor.isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在扫描开发服务…")
                                    .foregroundStyle(.secondary)
                            }
                            .listRowSeparator(.hidden)
                        } else {
                            Text("没有发现运行中的开发服务")
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        ForEach(monitor.runningProcesses) { process in
                            RunningServiceRow(
                                process: process,
                                name: monitor.name(for: process),
                                onOpenFolder: { openFolder(process.workingDirectory) },
                                onStop: { monitor.stop(process) }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)

            footer
        }
        .background(.background)
        .frame(height: preferredHeight)
    }

    private var preferredHeight: CGFloat {
        let runningCount = monitor.runningProcesses.count
        let runningRowsHeight: CGFloat = runningCount == 0 ? 42 : CGFloat(runningCount) * 88
        let messageHeight: CGFloat = monitor.message == nil ? 0 : 22

        let contentHeight = CGFloat(58 + 32 + 40) + runningRowsHeight + messageHeight
        return min(CGFloat(490), max(CGFloat(175), contentHeight))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本机服务")
                    .font(.system(size: 16, weight: .semibold))
                Text("展开时每秒更新 · 关闭后停止扫描")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")
            .accessibilityLabel("立即刷新")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = monitor.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Toggle(
                    "开机启动",
                    isOn: Binding(
                        get: { monitor.launchesAtLogin },
                        set: { monitor.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()

                if monitor.needsLoginApproval {
                    Button("打开登录项设置") {
                        monitor.openLoginItemsSettings()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                }

                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }

    private func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}

private struct RunningServiceRow: View {
    let process: ServiceProcess
    let name: String
    let onOpenFolder: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                nameLabel
                Spacer(minLength: 4)
                Text("\(process.processCount) 个进程 · PID \(process.pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Button(action: onOpenFolder) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(process.commandLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(process.workingDirectory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击在 Finder 中打开项目文件夹")
            .accessibilityLabel("打开项目文件夹：\(process.workingDirectory)")

            HStack(spacing: 10) {
                Label(memoryText, systemImage: "memorychip")
                    .help("启动器及其子进程的物理内存占用")
                Label(String(format: "%.1f%%", process.cpuPercent), systemImage: "cpu")
                    .help("启动器及其子进程最近 1 秒的 CPU 使用率")
                Spacer()
                Button(action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("停止该服务")
                .accessibilityLabel("停止 \(name)")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    /// 有监听端口时项目名可点击，用默认浏览器打开 http://localhost:端口。
    @ViewBuilder
    private var nameLabel: some View {
        if let url = process.browserURL, let port = process.listeningPorts.first {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(":\(port)")
                        .font(.system(size: 11, design: .monospaced))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(urlHelp(url))
            .accessibilityLabel("在浏览器打开 \(url.absoluteString)")
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .help("未检测到监听端口")
        }
    }

    private func urlHelp(_ url: URL) -> String {
        let others = process.listeningPorts.dropFirst().map(String.init)
        let base = "在默认浏览器打开 \(url.absoluteString)"
        return others.isEmpty ? base : "\(base)\n其他监听端口：\(others.joined(separator: "、"))"
    }

    private var memoryText: String {
        let megabytes = Double(process.residentBytes) / 1_048_576
        return megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : String(format: "%.0f MB", megabytes)
    }
}
