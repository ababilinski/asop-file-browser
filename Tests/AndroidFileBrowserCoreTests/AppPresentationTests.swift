import AppKit
import XCTest
@testable import AndroidFileBrowserCore

final class AppPresentationTests: XCTestCase {
    func testPackageUsesReadableNameAndStableInitialsBeforeMetadataLoads() {
        let package = makePackage(name: "com.example.camera_analyzer")

        XCTAssertEqual(package.displayName, "Camera Analyzer")
        XCTAssertEqual(package.displayInitials, "CA")
        XCTAssertTrue(0..<8 ~= package.artworkPaletteIndex)
    }

    func testDeviceLabelOverridesPackageNameFallback() {
        var package = makePackage(name: "com.google.android.apps.bard")
        package.appLabel = "Gemini"

        XCTAssertEqual(package.displayName, "Gemini")
        XCTAssertEqual(package.displayInitials, "GE")
    }

    func testMetadataBridgeParsesLabelAndImage() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let imageData = try XCTUnwrap(image.tiffRepresentation)
        let output = "com.example.camera\tCamera\t\(imageData.base64EncodedString())\n"

        let presentation = try XCTUnwrap(AppMetadataBridgeParser.parse(output)["com.example.camera"])

        XCTAssertEqual(presentation.label, "Camera")
        XCTAssertEqual(presentation.iconPNGData, imageData)
    }

    func testNarrowAppListPreservesMinimumColumnWidths() {
        let columns = AppColumn.allCases.filter { $0 != .apk }
        let layout = AppColumnMetrics.layout(
            for: columns,
            availableWidth: 320,
            preferredWidths: [:]
        )

        XCTAssertEqual(layout.width(for: .package), AppColumnMetrics.minimumWidth(for: .package))
        XCTAssertGreaterThan(layout.totalWidth, 320)
    }

    private func makePackage(name: String) -> AndroidPackage {
        AndroidPackage(
            packageName: name,
            apkPath: "/data/app/base.apk",
            kind: .user,
            enabled: true,
            versionName: "1.0",
            permissions: [],
            activities: [],
            receivers: [],
            services: [],
            providers: []
        )
    }
}
