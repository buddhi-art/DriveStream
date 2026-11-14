import SwiftUI

struct SettingsPerformanceTab: View {
    @Binding var draft: StreamConfig
    @ObservedObject var controller: MountController

    let onFreeUpSpace: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsSection(
                    title: "Local SSD cache",
                    subtitle: "Cached operations can be quick; uncached ranges depend on the connection. Retain pending writes until they reach Drive."
                ) {
                    SettingsRow("Cache limit", description: "The maximum space rclone may use on this Mac.") {
                        HStack(spacing: 6) {
                            TextField("10G", text: $draft.cacheMaxSize)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 84)
                            ForEach(["5G", "10G", "25G", "50G"], id: \.self) { preset in
                                Button(preset) {
                                    draft.cacheMaxSize = preset
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    SettingsRow("Cache age", description: "Files idle longer than this may be evicted.") {
                        HStack(spacing: 6) {
                            TextField("1h", text: $draft.cacheMaxAge)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 84)
                            ForEach(["30m", "1h", "6h", "24h"], id: \.self) { preset in
                                Button(preset) {
                                    draft.cacheMaxAge = preset
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Current usage")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ByteFormat.bytes(controller.telemetry.cacheBytes)) / \(draft.normalizedCacheMaxSize)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: cacheUsageFraction)
                            .tint(.orange)
                    }
                    HStack {
                        Label("\(controller.pinnedCount) pinned offline item\(controller.pinnedCount == 1 ? "" : "s")", systemImage: "pin")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Free Up Space Now") {
                            onFreeUpSpace()
                        }
                        .controlSize(.small)
                        .disabled(!controller.isMounted || controller.freeUpInProgress)
                    }
                    if let validation = draft.validationError {
                        Label(validation, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.red)
                    }
                }

                SettingsSection(title: "Memory and cache warming", subtitle: "Swift readers are bounded; no whole-drive file list is loaded into RAM.") {
                    SettingsRow("Resource policy", description: draft.performancePolicy.explanation) {
                        Picker("", selection: $draft.performanceMode) {
                            ForEach(PerformanceMode.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 220)
                    }
                    SettingsRow("Parallel file readers", description: "Automatic uses two on a small-memory Mac, four when memory is available.") {
                        Picker("", selection: $draft.pinConcurrency) {
                            Text("Automatic").tag(0)
                            ForEach(1...4, id: \.self) { Text(String($0)).tag($0) }
                        }.labelsHidden().frame(width: 120)
                    }
                }
                SettingsSection(title: "Bandwidth limits", subtitle: "0 means unlimited. Limits are binary MiB per second, upload then download.") {
                    SettingsRow("Upload", description: "Prevent background writes from filling the connection.") {
                        Stepper("\(draft.uploadLimitMiB) MiB/s", value: $draft.uploadLimitMiB, in: 0...10000).frame(width: 200)
                    }
                    SettingsRow("Download", description: "Apply a limit when using a hotspot or shared network.") {
                        Stepper("\(draft.downloadLimitMiB) MiB/s", value: $draft.downloadLimitMiB, in: 0...10000).frame(width: 200)
                    }
                }
                SettingsSection(
                    title: "Fixed Finder performance profile",
                    subtitle: "These tuned rclone flags are applied to every mount."
                ) {
                    EngineProfileRow(name: "Directory cache", value: "9999h")
                    EngineProfileRow(name: "Poll interval", value: "15s")
                    EngineProfileRow(name: "Attribute timeout", value: "1h")
                    EngineProfileRow(name: "Read chunk", value: "16M → 256M")
                    EngineProfileRow(name: "Read ahead", value: "64M")
                    EngineProfileRow(name: "Write-back delay", value: "5s")
                    EngineProfileRow(name: "Memory buffer", value: draft.performancePolicy.bufferSize + " per open file")
                    EngineProfileRow(name: "Transfers / checkers", value: "\(draft.performancePolicy.transfers) / 16")
                    EngineProfileRow(name: "Drive pacing", value: "10ms min · 200 burst")
                    EngineProfileRow(name: "Drive chunk", value: draft.performancePolicy.driveChunkSize)
                    EngineProfileRow(name: "Apple metadata", value: "AppleDouble + xattrs ignored")
                    Text("Changing the cache limit or age restarts the mounted volume so rclone can apply the new VFS flags.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(16)
        }
    }

    private var cacheUsageFraction: Double {
        let cap = draft.cacheCapBytes
        guard cap > 0 else { return 0 }
        return min(max(Double(controller.telemetry.cacheBytes) / Double(cap), 0), 1)
    }
}
