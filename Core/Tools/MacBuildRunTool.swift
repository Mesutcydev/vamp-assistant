import Foundation

/// Build a macOS app and launch it. Pair with `create_macos_app` so an agent
/// can go from empty folder → running window without inventing xcodebuild.
struct MacBuildRunTool: AgentTool {
    let name = "macos_build_run"
    let summary = "Build the macOS app and launch the resulting .app"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "project":{"type":"string","description":"Project directory (default: workspace root)"},
          "scheme":{"type":"string","description":"Xcode scheme (optional; auto-detected)"}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let project = call.string("project") ?? "."
        return .command("xcodebuild + open for \(project) (macOS)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let workspace = context.workspace
        let projectDir: URL
        if let project = call.string("project") {
            projectDir = try workspace.resolve(project, access: .read).url
        } else {
            projectDir = workspace.root
        }

        try Self.generateProjectIfNeeded(in: projectDir)

        let projectFile = try Self.detectProject(in: projectDir)
        let scheme = call.string("scheme") ?? Self.detectScheme(projectFile)

        let derivedData = workspace.root.appendingPathComponent(".beetcode/DerivedData", isDirectory: true)
        try? FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let build = try ShellRunner.runProcess(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-project", projectFile.path,
                "-scheme", scheme,
                "-destination", "platform=macOS",
                "-derivedDataPath", derivedData.path,
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            workingDirectory: projectDir,
            timeout: 600)
        guard !build.timedOut else {
            return "error: build timed out after 600s\n" + RunCommandTool.truncate(build.output)
        }
        guard build.exitCode == 0 else {
            let diagnostics = DiagnosticParser.parse(build.output)
            return DiagnosticParser.render(diagnostics)
                + "\n\nraw output:\n" + RunCommandTool.truncate(build.output, limit: 8_000)
        }

        guard let appURL = BuiltAppLocator.findBuiltApp(
            in: derivedData, sdk: .macOS, buildOutput: build.output)
        else {
            return "error: build succeeded but no .app found in \(derivedData.path)"
        }

        let launch = try ShellRunner.runProcess(
            executable: "/usr/bin/open",
            arguments: ["-n", appURL.path],
            workingDirectory: projectDir,
            timeout: 15)
        if launch.exitCode != 0 {
            return "Build: succeeded (\(scheme))\nApp: \(appURL.path)\nLaunch failed: \(launch.output)"
        }
        return """
        Build: succeeded (\(scheme))
        App: \(appURL.path)
        Launch: opened
        The macOS app is running. Use computer_ui_tree / computer_screenshot if you need to verify the window.
        """
    }

    static func generateProjectIfNeeded(in dir: URL) throws {
        let yml = dir.appendingPathComponent("project.yml")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasXcodeproj = contents.contains(where: { $0.hasSuffix(".xcodeproj") })
        guard FileManager.default.fileExists(atPath: yml.path), !hasXcodeproj,
              let xcodegen = CreateMacAppTool.xcodegenURL()
        else { return }
        _ = try ShellRunner.runProcess(
            executable: xcodegen.path,
            arguments: ["generate"],
            workingDirectory: dir,
            timeout: 60)
    }

    private static func detectProject(in dir: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return dir.appendingPathComponent(xcodeproj)
        }
        throw ToolError.missingArgument("project — no .xcodeproj found in \(dir.path). Run create_macos_app or xcodegen generate.")
    }

    private static func detectScheme(_ projectFile: URL) -> String {
        projectFile.deletingPathExtension().lastPathComponent
    }
}

/// Locates the product `.app` after `xcodebuild`. The first match in
/// DerivedData is often a leftover (`BeetCode.app` after a PRODUCT_NAME
/// rename, an older Debug stub, a UITest runner, or an iOS simulator
/// product sitting next to a macOS one).
enum BuiltAppLocator {
    enum SDK: Equatable {
        case macOS
        case iOSSimulator

        func matchesProductFolder(_ name: String) -> Bool {
            switch self {
            case .macOS:
                return name == "Debug" || name == "Release"
                    || name.hasSuffix("-macos") || name.hasSuffix("-macosx")
            case .iOSSimulator:
                return name.contains("iphonesimulator")
            }
        }
    }

    static func findBuiltApp(in derivedData: URL, sdk: SDK, buildOutput: String? = nil) -> URL? {
        if let fromLog = appURL(fromBuildOutput: buildOutput),
           FileManager.default.fileExists(atPath: fromLog.path) {
            return fromLog
        }
        return newestLaunchableApp(in: derivedData, sdk: sdk)
    }

    static func appURL(fromBuildOutput output: String?) -> URL? {
        guard let output, !output.isEmpty else { return nil }
        var last: URL?
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Touch ")
                    || trimmed.hasPrefix("CodeSign ")
                    || trimmed.hasPrefix("Validate ") else { continue }
            let rest = trimmed.drop { $0 != " " }.dropFirst()
            let pathPart: Substring
            if let range = rest.range(of: " (in target") {
                pathPart = rest[..<range.lowerBound]
            } else {
                pathPart = rest
            }
            let path = String(pathPart).trimmingCharacters(in: .whitespaces)
            guard path.hasSuffix(".app"), !path.hasSuffix(".appex") else { continue }
            let url = URL(fileURLWithPath: path)
            guard isLaunchableAppName(url.deletingPathExtension().lastPathComponent) else { continue }
            last = url
        }
        return last
    }

    static func isLaunchableAppName(_ name: String) -> Bool {
        !name.hasSuffix("Tests") && !name.hasSuffix("-Runner") && !name.hasSuffix("UITests")
    }

    static func newestLaunchableApp(in derivedData: URL, sdk: SDK) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var ranked: [(URL, Date)] = []
        for folder in folders where sdk.matchesProductFolder(folder.lastPathComponent) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where child.pathExtension == "app" {
                guard isLaunchableAppName(child.deletingPathExtension().lastPathComponent) else { continue }
                let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                ranked.append((child, date))
            }
        }
        return ranked.max(by: { $0.1 < $1.1 })?.0
    }
}
