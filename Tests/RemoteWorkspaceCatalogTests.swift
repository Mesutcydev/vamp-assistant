import Foundation
import XCTest
@testable import BeetCode

final class RemoteWorkspaceCatalogTests: XCTestCase {

    func testSanitizeFolderNameRejectsTraversalAndHiddenNames() {
        XCTAssertEqual(RemoteWorkspaceCatalog.sanitizeFolderName(" My App "), "My App")
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName(""))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName("."))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName(".."))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName(".hidden"))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName("foo/bar"))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName("foo\\bar"))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName("C:Windows"))
        XCTAssertNil(RemoteWorkspaceCatalog.sanitizeFolderName(String(repeating: "x", count: 65)))
    }

    func testCreateFolderStaysInsideInjectableHome() throws {
        let home = TempWorkspace()
        let created = try RemoteWorkspaceCatalog.createFolder(
            name: "Demo",
            parentPath: nil,
            home: home.url,
            knownPaths: [])
        let expectedParent = RemoteWorkspaceCatalog.defaultCreateParent(home: home.url)
        XCTAssertEqual(created.deletingLastPathComponent().standardizedFileURL, expectedParent.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(created.lastPathComponent, "Demo")

        let again = try RemoteWorkspaceCatalog.createFolder(
            name: "Demo",
            parentPath: nil,
            home: home.url,
            knownPaths: [])
        XCTAssertEqual(again.standardizedFileURL.path, created.standardizedFileURL.path)
    }

    func testResolveExistingRejectsFoldersOutsideHomeUnlessAlreadyKnown() throws {
        let home = TempWorkspace()
        let outside = TempWorkspace()
        XCTAssertThrowsError(
            try RemoteWorkspaceCatalog.resolveExisting(
                outside.url.path, home: home.url, knownPaths: [])
        ) { error in
            XCTAssertEqual(error as? RemoteWorkspaceCatalog.CatalogError, .outsideHome)
        }

        let allowed = try RemoteWorkspaceCatalog.resolveExisting(
            outside.url.path, home: home.url, knownPaths: [outside.url.path])
        XCTAssertEqual(
            allowed.standardizedFileURL.path,
            outside.url.resolvingSymlinksInPath().standardizedFileURL.path)

        XCTAssertThrowsError(
            try RemoteWorkspaceCatalog.resolveExisting(
                home.url.appendingPathComponent("missing").path,
                home: home.url,
                knownPaths: [])
        ) { error in
            XCTAssertEqual(error as? RemoteWorkspaceCatalog.CatalogError, .missingFolder)
        }
    }

    func testListSkipsMissingFoldersAndMarksTheCurrentOne() {
        let home = TempWorkspace()
        let current = home.makeDirectory("current")
        let older = home.makeDirectory("older")
        let items = RemoteWorkspaceCatalog.list(
            currentPath: current.path,
            lastPath: home.url.appendingPathComponent("gone").path,
            records: [
                (path: older.path, updatedAt: Date().addingTimeInterval(-60)),
                (path: "/definitely-missing-\(UUID().uuidString)", updatedAt: Date()),
            ])
        XCTAssertEqual(Set(items.map(\.name)), ["current", "older"])
        XCTAssertEqual(items.first { $0.name == "current" }?.isCurrent, true)
        XCTAssertEqual(items.first { $0.name == "older" }?.isCurrent, false)
    }

    func testResolveExistingRejectsHomeAndSensitiveFolders() throws {
        let home = TempWorkspace()
        XCTAssertThrowsError(
            try RemoteWorkspaceCatalog.resolveExisting(
                home.url.path, home: home.url, knownPaths: [])
        ) { error in
            XCTAssertEqual(error as? RemoteWorkspaceCatalog.CatalogError, .sensitiveFolder)
        }

        let ssh = home.makeDirectory(".ssh")
        XCTAssertThrowsError(
            try RemoteWorkspaceCatalog.resolveExisting(
                ssh.path, home: home.url, knownPaths: [ssh.path])
        ) { error in
            XCTAssertEqual(error as? RemoteWorkspaceCatalog.CatalogError, .sensitiveFolder)
        }

        let library = home.makeDirectory("Library")
        XCTAssertThrowsError(
            try RemoteWorkspaceCatalog.resolveExisting(
                library.path, home: home.url, knownPaths: [])
        ) { error in
            XCTAssertEqual(error as? RemoteWorkspaceCatalog.CatalogError, .sensitiveFolder)
        }

        let docs = home.makeDirectory("Documents")
        let allowed = try RemoteWorkspaceCatalog.resolveExisting(
            docs.path, home: home.url, knownPaths: [])
        XCTAssertEqual(allowed.lastPathComponent, "Documents")
    }

    func testListOmitsSensitiveFolders() {
        let home = TempWorkspace()
        let project = home.makeDirectory("project")
        let ssh = home.makeDirectory(".ssh")
        let items = RemoteWorkspaceCatalog.list(
            currentPath: project.path,
            lastPath: ssh.path,
            records: [(path: ssh.path, updatedAt: Date())],
            home: home.url)
        XCTAssertEqual(items.map(\.name), ["project"])
    }

    func testCreateFolderCreatesMissingDefaultParent() throws {
        let home = TempWorkspace()
        let parent = RemoteWorkspaceCatalog.defaultCreateParent(home: home.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        let created = try RemoteWorkspaceCatalog.createFolder(
            name: "Demo",
            parentPath: parent.path,
            home: home.url,
            knownPaths: [])
        XCTAssertEqual(created.lastPathComponent, "Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(
            created.deletingLastPathComponent().standardizedFileURL.path,
            parent.standardizedFileURL.path)
    }

    func testCreateFolderAllowsICloudDocumentsSymlink() throws {
        let home = TempWorkspace()
        let realDocs = home.makeDirectory("Library/Mobile Documents/iCloud/Documents")
        let documents = home.url.appendingPathComponent("Documents")
        try FileManager.default.createSymbolicLink(
            atPath: documents.path,
            withDestinationPath: realDocs.path)
        let parent = RemoteWorkspaceCatalog.defaultCreateParent(home: home.url)
        let created = try RemoteWorkspaceCatalog.createFolder(
            name: "Demo",
            parentPath: parent.path,
            home: home.url,
            knownPaths: [])
        XCTAssertEqual(created.lastPathComponent, "Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        let resolved = try RemoteWorkspaceCatalog.resolveExisting(
            created.path, home: home.url, knownPaths: [])
        XCTAssertEqual(resolved.lastPathComponent, "Demo")
    }

    func testListOmitsBotComputerWorkspaces() {
        let home = TempWorkspace()
        let project = home.makeDirectory("Documents/App")
        let botWorkspace = home.makeDirectory(
            "Library/Application Support/BeetCode/BotComputers/\(UUID().uuidString)/workspace")
        let items = RemoteWorkspaceCatalog.list(
            currentPath: project.path,
            lastPath: botWorkspace.path,
            records: [(path: botWorkspace.path, updatedAt: Date())],
            home: home.url)
        XCTAssertEqual(items.map(\.name), ["App"])
    }
}
