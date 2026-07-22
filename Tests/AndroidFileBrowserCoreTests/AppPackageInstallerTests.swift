import XCTest
@testable import AndroidFileBrowserCore

final class AppPackageInstallerTests: XCTestCase {
    func testSupportedSelectionAcceptsInstallablePackageShapes() {
        XCTAssertTrue(AppPackageInstaller.isSupportedSelection([URL(fileURLWithPath: "/tmp/app.apk")]))
        XCTAssertTrue(AppPackageInstaller.isSupportedSelection([
            URL(fileURLWithPath: "/tmp/base.apk"),
            URL(fileURLWithPath: "/tmp/config.arm64.apk")
        ]))
        XCTAssertTrue(AppPackageInstaller.isSupportedSelection([URL(fileURLWithPath: "/tmp/app.xapk")]))
        XCTAssertTrue(AppPackageInstaller.isSupportedSelection([URL(fileURLWithPath: "/tmp/app.apks")]))
        XCTAssertTrue(AppPackageInstaller.isSupportedSelection([URL(fileURLWithPath: "/tmp/splits.zip")]))
    }

    func testSupportedSelectionRejectsMixedOrUnrelatedFiles() {
        XCTAssertFalse(AppPackageInstaller.isSupportedSelection([]))
        XCTAssertFalse(AppPackageInstaller.isSupportedSelection([URL(fileURLWithPath: "/tmp/readme.txt")]))
        XCTAssertFalse(AppPackageInstaller.isSupportedSelection([
            URL(fileURLWithPath: "/tmp/app.apk"),
            URL(fileURLWithPath: "/tmp/app.xapk")
        ]))
    }

    func testArchiveEntryValidationRejectsTraversalAndAbsolutePaths() {
        XCTAssertTrue(AppPackageInstaller.isSafeArchiveEntry("splits/base.apk"))
        XCTAssertTrue(AppPackageInstaller.isSafeArchiveEntry("Android/obb/com.example/"))
        XCTAssertFalse(AppPackageInstaller.isSafeArchiveEntry("../base.apk"))
        XCTAssertFalse(AppPackageInstaller.isSafeArchiveEntry("splits/../../base.apk"))
        XCTAssertFalse(AppPackageInstaller.isSafeArchiveEntry("/tmp/base.apk"))
        XCTAssertFalse(AppPackageInstaller.isSafeArchiveEntry("splits//base.apk"))
    }

    func testDowngradeFailureCreatesRecoverableConflict() throws {
        let issue = AppInstallFailureParser.issue(
            from: "Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected]"
        )
        let conflict = try XCTUnwrap(issue as? AppInstallConflict)
        XCTAssertEqual(conflict.kind, .newerVersionInstalled)
    }

    func testSignatureFailureExtractsInstalledPackageName() throws {
        let issue = AppInstallFailureParser.issue(
            from: "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.example.reader signatures do not match newer version]"
        )
        let conflict = try XCTUnwrap(issue as? AppInstallConflict)
        XCTAssertEqual(conflict.kind, .differentSignature)
        XCTAssertEqual(conflict.packageName, "com.example.reader")
        XCTAssertTrue(conflict.localizedDescription.contains("signed differently"))
    }

    func testDowngradeConflictExplainsWhyInstallCannotContinue() {
        let conflict = AppInstallConflict(
            kind: .newerVersionInstalled,
            packageName: "com.example.reader",
            details: "INSTALL_FAILED_VERSION_DOWNGRADE"
        )

        XCTAssertTrue(conflict.localizedDescription.contains("newer version installed"))
        XCTAssertTrue(conflict.localizedDescription.contains("remove the installed copy"))
    }

    func testCommonInstallFailuresBecomeActionableIssues() {
        XCTAssertEqual(
            AppInstallFailureParser.issue(from: "INSTALL_FAILED_INSUFFICIENT_STORAGE") as? AppPackageInstallError,
            .insufficientStorage
        )
        XCTAssertEqual(
            AppInstallFailureParser.issue(from: "INSTALL_FAILED_NO_MATCHING_ABIS") as? AppPackageInstallError,
            .incompatibleDevice
        )
        XCTAssertEqual(
            AppInstallFailureParser.issue(from: "INSTALL_FAILED_MISSING_SPLIT") as? AppPackageInstallError,
            .incompleteSplitSet
        )
        XCTAssertEqual(
            AppInstallFailureParser.issue(from: "INSTALL_FAILED_USER_RESTRICTED") as? AppPackageInstallError,
            .installBlocked
        )
        XCTAssertEqual(
            AppInstallFailureParser.issue(from: "INSTALL_PARSE_FAILED_NO_CERTIFICATES") as? AppPackageInstallError,
            .invalidPackage
        )
    }
}
