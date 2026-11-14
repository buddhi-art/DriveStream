import Foundation

enum VolumePresenter {
    /// Best-effort post-mount Finder polish. Runs off the main actor because writing
    /// to a cloud-backed mount can block on the first metadata write.
    static func prepare(mountPath: String, suppressSpotlight: Bool, showDesktopIcons: Bool) async {
        let fileManager = FileManager.default
        let mountURL = URL(fileURLWithPath: mountPath, isDirectory: true)

        if suppressSpotlight {
            let metadataURL = mountURL.appendingPathComponent(".metadata_never_index")
            if !fileManager.fileExists(atPath: metadataURL.path) {
                var created = false
                for _ in 0..<3 {
                    created = fileManager.createFile(atPath: metadataURL.path, contents: Data())
                    if created { break }
                    try? await Task.sleep(for: .milliseconds(600))
                }
                if !created {
                    NSLog("[DriveStream] Could not create .metadata_never_index at \(mountPath)")
                }
            }
        }

        // Prefer the real macOS external-drive icon, then the DriveStream-branded
        // fallback shipped in the app bundle. Writing via Data avoids copying
        // extended attributes that a --noapplexattr mount rejects.
        let nativeIconPath = "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns"
        var iconCandidates: [URL] = [URL(fileURLWithPath: nativeIconPath)]
        if let bundledIcon = Bundle.main.url(forResource: "VolumeIcon", withExtension: "icns") {
            iconCandidates.append(bundledIcon)
        }
        let iconDestination = mountURL.appendingPathComponent(".VolumeIcon.icns")
        var destinationExists = fileManager.fileExists(atPath: iconDestination.path)
        if !destinationExists {
            for iconSource in iconCandidates where fileManager.fileExists(atPath: iconSource.path) {
                do {
                    let iconData = try Data(contentsOf: iconSource)
                    do {
                        try iconData.write(to: iconDestination, options: .atomic)
                    } catch {
                        try iconData.write(to: iconDestination)
                    }
                    destinationExists = fileManager.fileExists(atPath: iconDestination.path)
                    if destinationExists { break }
                } catch {
                    NSLog("[DriveStream] Could not install .VolumeIcon.icns from \(iconSource.path): \(error.localizedDescription)")
                }
            }
        }
        if destinationExists {
            _ = try? await CommandRunner.run(
                executable: "/usr/bin/SetFile",
                arguments: ["-a", "C", mountPath],
                timeout: 10
            )
            VolumeIconFlag.markCustomIcon(at: mountPath)
        } else {
            NSLog("[DriveStream] No source icon was available for .VolumeIcon.icns.")
        }

        await FinderIntegrationService.applyFinderPreferences(showDesktopIcons: showDesktopIcons)
    }
}
