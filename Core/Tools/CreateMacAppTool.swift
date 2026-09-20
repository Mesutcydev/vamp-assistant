import Foundation

/// Scaffolds a native Apple Silicon macOS SwiftUI app (XcodeGen) so an API
/// model can go from empty folder → buildable project without inventing a
/// pbxproj by hand.
struct CreateMacAppTool: AgentTool {
    let name = "create_macos_app"
    let summary = "Scaffold a native Apple Silicon macOS SwiftUI app (XcodeGen + xcodebuild-ready)"
    let risk = ToolRisk.write

    let schemaText = """
        {"type":"object","properties":{
          "name":{"type":"string","description":"App name (letters, numbers, spaces). Becomes the target and product."},
          "bundleId":{"type":"string","description":"Optional bundle id (default com.example.<slug>)"},
          "path":{"type":"string","description":"Directory inside the workspace to create (default: workspace root)"},
          "overwrite":{"type":"boolean","default":false,"description":"Replace existing project.yml, AGENTS.md, and App/ files in the destination"}
        },"required":["name"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let name = call.string("name") ?? "App"
        let path = call.string("path") ?? "."
        let overwrite = call.bool("overwrite") ?? false
        return .command("scaffold macOS app “\(name)” in \(path)" + (overwrite ? " (replacing existing scaffold files)" : ""))
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let rawName = call.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty
        else { throw ToolError.missingArgument("name") }

        let product = Self.sanitizeProduct(rawName)
        guard !product.isEmpty else {
            throw ToolError.missingArgument("name")
        }
        let slug = product.lowercased()
        let requestedBundle = try Self.validatedBundleId(call.string("bundleId"))
        let bundle = requestedBundle.isEmpty ? "com.example.\(slug)" : requestedBundle
        let displayName = Self.safeDisplayName(rawName)
        let overwrite = call.bool("overwrite") ?? false

        let dest: URL
        if let rel = call.string("path"), !rel.isEmpty, rel != "." {
            dest = try context.workspace.resolve(rel, access: .write).url
        } else {
            dest = context.workspace.root
        }
        try Self.ensureScaffoldDestinationIsSafe(dest: dest, overwrite: overwrite)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try Self.writeScaffold(product: product, displayName: displayName, bundleId: bundle, dest: dest)

        var notes = [
            "Created \(product) at \(dest.path)",
            "bundle id: \(bundle)",
            "files: project.yml, App/\(product)App.swift, App/ContentView.swift, App/Info.plist, AGENTS.md",
        ]

        if let xcodegen = Self.xcodegenURL() {
            let generate = try ShellRunner.runProcess(
                executable: xcodegen.path,
                arguments: ["generate"],
                workingDirectory: dest,
                timeout: 60)
            if generate.exitCode == 0 {
                notes.append("xcodegen generate: ok → \(product).xcodeproj")
            } else {
                notes.append("xcodegen generate failed (exit \(generate.exitCode)). Run it yourself, then build_diagnostics.")
            }
        } else {
            notes.append("xcodegen not on PATH — `brew install xcodegen`, then `xcodegen generate` in this folder.")
        }

        notes.append("Next: macos_build_run (build + launch) or build_diagnostics.")
        return notes.joined(separator: "\n")
    }

    static func sanitizeProduct(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : Character(" ") }
        let words = String(scalars).split(separator: " ").map { part -> String in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }
        return words.joined()
    }

    /// Scaffold files that must never be replaced silently: a `project.yml`,
    /// `App/` tree, or `AGENTS.md` already present means the destination is an
    /// existing project, not an empty scaffold target.
    static let scaffoldConflicts = ["project.yml", "AGENTS.md", "App"]

    static func ensureScaffoldDestinationIsSafe(dest: URL, overwrite: Bool) throws {
        let existing = scaffoldConflicts.filter {
            FileManager.default.fileExists(atPath: dest.appendingPathComponent($0).path)
        }
        guard existing.isEmpty || overwrite else {
            let list = existing.joined(separator: ", ")
            throw ToolError.scaffoldWouldOverwrite(
                "'\(dest.path)' already contains \(list)")
        }
    }

    /// Display names land in generated Swift string literals, YAML, and XML
    /// plists. Strip the characters that would break or inject into any of
    /// them; the product name and bundle id stay separately validated.
    static func safeDisplayName(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            switch scalar {
            case "\"", "\\", "`", "<", ">", "&": return false
            default: return true
            }
        }
        let value = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "App" : value
    }

    /// Returns "" when no bundle id was requested; otherwise validates the
    /// reverse-DNS shape before it is interpolated into XcodeGen YAML.
    static func validatedBundleId(_ raw: String?) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let pattern = #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw ToolError.invalidArguments(
                "bundleId '\(trimmed)' must look like com.example.app (letters, digits, dots, hyphens)")
        }
        return trimmed
    }

    static func xcodegenURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/xcodegen",
            "/usr/local/bin/xcodegen",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        return nil
    }

    static func writeScaffold(product: String, displayName: String, bundleId: String, dest: URL) throws {
        let appDir = dest.appendingPathComponent("App", isDirectory: true)
        let assets = appDir.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        try """
        name: \(product)
        options:
          bundleIdPrefix: \(bundlePrefix(bundleId))
          deploymentTarget:
            macOS: "15.0"
          createIntermediateGroups: true
          projectFormat: xcode16_0

        settings:
          base:
            SWIFT_VERSION: "6.0"
            ARCHS: arm64
            EXCLUDED_ARCHS: x86_64

        targets:
          \(product):
            type: application
            platform: macOS
            sources:
              - App
            resources:
              - App/Assets.xcassets
            info:
              path: App/Info.plist
              properties:
                CFBundleDisplayName: "\(displayName)"
                CFBundleShortVersionString: "0.1.0"
                CFBundleVersion: "1"
                LSApplicationCategoryType: public.app-category.developer-tools
                LSMinimumSystemVersion: "15.0"
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: \(bundleId)
                GENERATE_INFOPLIST_FILE: NO
                CODE_SIGN_IDENTITY: "-"
                ENABLE_APP_SANDBOX: NO
                SUPPORTS_MACCATALYST: NO
                SWIFT_STRICT_CONCURRENCY: minimal

        schemes:
          \(product):
            build:
              targets:
                \(product): all
            run:
              config: Debug
        """.write(to: dest.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)

        try """
        import SwiftUI

        @main
        struct \(product)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """.write(to: appDir.appendingPathComponent("\(product)App.swift"), atomically: true, encoding: .utf8)

        try """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 12) {
                    Text("\(displayName)")
                        .font(.largeTitle.weight(.semibold))
                    Text("Replace this view and run build_diagnostics.")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 480, minHeight: 320)
                .padding()
            }
        }
        """.write(to: appDir.appendingPathComponent("ContentView.swift"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>$(DEVELOPMENT_LANGUAGE)</string>
            <key>CFBundleDisplayName</key>
            <string>\(displayName)</string>
            <key>CFBundleExecutable</key>
            <string>$(EXECUTABLE_NAME)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>0.1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>15.0</string>
        </dict>
        </plist>
        """.write(to: appDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        try """
        {
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """.write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        try """
        # \(displayName)

        Native Apple Silicon macOS app. Source of truth is `project.yml`.

        ```sh
        xcodegen generate
        xcodebuild -project \(product).xcodeproj -scheme \(product) \\
          -destination 'platform=macOS' build
        ```

        After adding or removing Swift files, run `xcodegen generate` again.
        """.write(to: dest.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    }

    static func bundlePrefix(_ bundleId: String) -> String {
        let parts = bundleId.split(separator: ".")
        guard parts.count >= 2 else { return bundleId }
        return parts.dropLast().joined(separator: ".")
    }
}

/// Scaffolds a native iOS SwiftUI app (XcodeGen) ready for `sim_build_run`.
struct CreateIOSAppTool: AgentTool {
    let name = "create_ios_app"
    let summary = "Scaffold a native iOS SwiftUI app (XcodeGen + iOS Simulator-ready)"
    let risk = ToolRisk.write

    let schemaText = """
        {"type":"object","properties":{
          "name":{"type":"string","description":"App name (letters, numbers, spaces). Becomes the target and product."},
          "bundleId":{"type":"string","description":"Optional bundle id (default com.example.<slug>)"},
          "path":{"type":"string","description":"Directory inside the workspace to create (default: workspace root)"},
          "overwrite":{"type":"boolean","default":false,"description":"Replace existing project.yml, AGENTS.md, and App/ files in the destination"}
        },"required":["name"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let name = call.string("name") ?? "App"
        let path = call.string("path") ?? "."
        let overwrite = call.bool("overwrite") ?? false
        return .command("scaffold iOS app “\(name)” in \(path)" + (overwrite ? " (replacing existing scaffold files)" : ""))
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let rawName = call.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty
        else { throw ToolError.missingArgument("name") }

        let product = CreateMacAppTool.sanitizeProduct(rawName)
        guard !product.isEmpty else { throw ToolError.missingArgument("name") }
        let slug = product.lowercased()
        let requestedBundle = try CreateMacAppTool.validatedBundleId(call.string("bundleId"))
        let bundle = requestedBundle.isEmpty ? "com.example.\(slug)" : requestedBundle
        let displayName = CreateMacAppTool.safeDisplayName(rawName)
        let overwrite = call.bool("overwrite") ?? false

        let dest: URL
        if let rel = call.string("path"), !rel.isEmpty, rel != "." {
            dest = try context.workspace.resolve(rel, access: .write).url
        } else {
            dest = context.workspace.root
        }
        try CreateMacAppTool.ensureScaffoldDestinationIsSafe(dest: dest, overwrite: overwrite)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Self.writeScaffold(product: product, displayName: displayName, bundleId: bundle, dest: dest)

        var notes = [
            "Created \(product) (iOS) at \(dest.path)",
            "bundle id: \(bundle)",
            "files: project.yml, App/\(product)App.swift, App/ContentView.swift, App/Info.plist, AGENTS.md",
        ]
        if let xcodegen = CreateMacAppTool.xcodegenURL() {
            let generate = try ShellRunner.runProcess(
                executable: xcodegen.path,
                arguments: ["generate"],
                workingDirectory: dest,
                timeout: 60)
            if generate.exitCode == 0 {
                notes.append("xcodegen generate: ok → \(product).xcodeproj")
            } else {
                notes.append("xcodegen generate failed (exit \(generate.exitCode)). Run it yourself, then sim_build_run.")
            }
        } else {
            notes.append("xcodegen not on PATH — `brew install xcodegen`, then `xcodegen generate` in this folder.")
        }
        notes.append("Next: sim_build_run (build → install → launch → screenshot).")
        return notes.joined(separator: "\n")
    }

    static func writeScaffold(product: String, displayName: String, bundleId: String, dest: URL) throws {
        let appDir = dest.appendingPathComponent("App", isDirectory: true)
        let assets = appDir.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        try """
        name: \(product)
        options:
          bundleIdPrefix: \(CreateMacAppTool.bundlePrefix(bundleId))
          deploymentTarget:
            iOS: "18.0"
          createIntermediateGroups: true
          projectFormat: xcode16_0

        settings:
          base:
            SWIFT_VERSION: "6.0"
            TARGETED_DEVICE_FAMILY: "1,2"

        targets:
          \(product):
            type: application
            platform: iOS
            sources:
              - App
            resources:
              - App/Assets.xcassets
            info:
              path: App/Info.plist
              properties:
                CFBundleDisplayName: "\(displayName)"
                CFBundleShortVersionString: "0.1.0"
                CFBundleVersion: "1"
                UILaunchScreen: {}
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: \(bundleId)
                GENERATE_INFOPLIST_FILE: NO
                CODE_SIGN_IDENTITY: "-"
                CODE_SIGNING_ALLOWED: NO
                SWIFT_STRICT_CONCURRENCY: minimal

        schemes:
          \(product):
            build:
              targets:
                \(product): all
            run:
              config: Debug
        """.write(to: dest.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)

        try """
        import SwiftUI

        @main
        struct \(product)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """.write(to: appDir.appendingPathComponent("\(product)App.swift"), atomically: true, encoding: .utf8)

        try """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 12) {
                    Text("\(displayName)")
                        .font(.largeTitle.weight(.semibold))
                    Text("Replace this view and run sim_build_run.")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        """.write(to: appDir.appendingPathComponent("ContentView.swift"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>$(DEVELOPMENT_LANGUAGE)</string>
            <key>CFBundleDisplayName</key>
            <string>\(displayName)</string>
            <key>CFBundleExecutable</key>
            <string>$(EXECUTABLE_NAME)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>0.1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>UILaunchScreen</key>
            <dict/>
            <key>UISupportedInterfaceOrientations</key>
            <array>
                <string>UIInterfaceOrientationPortrait</string>
                <string>UIInterfaceOrientationLandscapeLeft</string>
                <string>UIInterfaceOrientationLandscapeRight</string>
            </array>
        </dict>
        </plist>
        """.write(to: appDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        try """
        {
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """.write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

        try """
        # \(displayName)

        Native iOS SwiftUI app. Source of truth is `project.yml`.

        ```sh
        xcodegen generate
        xcodebuild -project \(product).xcodeproj -scheme \(product) \\
          -destination 'platform=iOS Simulator,name=iPhone 16' \\
          -derivedDataPath .beetcode/DerivedData build
        ```

        In Beet Code, prefer `sim_build_run` after edits. After adding or
        removing Swift files, run `xcodegen generate` again.
        """.write(to: dest.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    }
}
