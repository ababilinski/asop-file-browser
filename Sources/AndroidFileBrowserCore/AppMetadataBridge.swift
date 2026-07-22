import Foundation
import ImageIO

struct AndroidAppPresentation: Equatable, Sendable {
    let packageName: String
    let label: String?
    let iconPNGData: Data?
}

enum AppMetadataBridgeParser {
    static func parse(_ output: String) -> [String: AndroidAppPresentation] {
        var presentations: [String: AndroidAppPresentation] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            let packageName = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !packageName.isEmpty else { continue }
            let rawLabel = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let iconData = Data(base64Encoded: String(fields[2])).flatMap { data in
                CGImageSourceCreateWithData(data as CFData, nil) == nil ? nil : data
            }
            guard !rawLabel.isEmpty || iconData != nil else { continue }

            presentations[packageName] = AndroidAppPresentation(
                packageName: packageName,
                label: rawLabel.isEmpty ? nil : rawLabel,
                iconPNGData: iconData
            )
        }
        return presentations
    }
}

actor AppMetadataBridge {
    private static let remotePayloadPath = "/data/local/tmp/asop-file-browser-metadata-v1.dex"
    private static let mainClass = "com.asopfilebrowser.metadata.AppMetadataBridge"
    private static let batchSize = 32

    private let adb: ADBClient
    private var presentationsByCacheKey: [String: AndroidAppPresentation] = [:]

    init(adb: ADBClient) {
        self.adb = adb
    }

    func presentations(
        device: AndroidDevice,
        packages: [AndroidPackage],
        onBatch: (@Sendable ([String: AndroidAppPresentation]) async throws -> Void)? = nil
    ) async throws -> [String: AndroidAppPresentation] {
        let eligiblePackages = packages.filter { $0.apkPath != nil }
        var result: [String: AndroidAppPresentation] = [:]
        var missing: [AndroidPackage] = []

        for package in eligiblePackages {
            let key = cacheKey(deviceSerial: device.serial, package: package)
            if let cached = presentationsByCacheKey[key] {
                result[package.packageName] = cached
            } else {
                missing.append(package)
            }
        }
        if let onBatch, !result.isEmpty {
            try await onBatch(result)
        }
        guard !missing.isEmpty else { return result }

        let localPayloadURL = FileManager.default.temporaryDirectory
            .appending(path: "asop-file-browser-metadata-\(UUID().uuidString).dex")
        try AppMetadataBridgePayload.data.write(to: localPayloadURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: localPayloadURL.path
        )
        defer { try? FileManager.default.removeItem(at: localPayloadURL) }

        _ = try await adb.run(
            ["-s", device.serial, "push", localPayloadURL.path, Self.remotePayloadPath],
            timeout: 12
        )

        do {
            for batchStart in stride(from: 0, to: missing.count, by: Self.batchSize) {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + Self.batchSize, missing.count)
                let batch = missing[batchStart..<batchEnd]
                let arguments = batch.flatMap { package -> [String] in
                    [package.packageName, package.apkPath ?? ""]
                }
                .map(ADBClient.quoteRemote)
                .joined(separator: " ")
                let command = "CLASSPATH=\(Self.remotePayloadPath) app_process /system/bin \(Self.mainClass) \(arguments)"
                let commandResult = try await adb.shell(
                    serial: device.serial,
                    command,
                    allowFailure: true,
                    timeout: 30
                )

                var batchPresentations: [String: AndroidAppPresentation] = [:]
                for (packageName, presentation) in AppMetadataBridgeParser.parse(commandResult.stdout) {
                    guard let package = batch.first(where: { $0.packageName == packageName }) else { continue }
                    presentationsByCacheKey[cacheKey(deviceSerial: device.serial, package: package)] = presentation
                    result[packageName] = presentation
                    batchPresentations[packageName] = presentation
                }
                if let onBatch, !batchPresentations.isEmpty {
                    try await onBatch(batchPresentations)
                }
            }
            await removeRemotePayload(deviceSerial: device.serial)
            return result
        } catch {
            await removeRemotePayload(deviceSerial: device.serial)
            throw error
        }
    }

    private func removeRemotePayload(deviceSerial: String) async {
        _ = try? await adb.shell(
            serial: deviceSerial,
            "rm -f \(Self.remotePayloadPath)",
            allowFailure: true,
            timeout: 5
        )
    }

    private func cacheKey(deviceSerial: String, package: AndroidPackage) -> String {
        "\(deviceSerial)|\(package.packageName)|\(package.apkPath ?? "")"
    }
}
