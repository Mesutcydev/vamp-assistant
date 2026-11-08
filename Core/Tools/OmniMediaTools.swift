import Foundation

struct AnalyzeMediaTool: AgentTool {
    let name = "analyze_media"
    let summary = "Analyze a local audio, video (including soundtrack), or image file with the loaded local Omni model"
    let risk = ToolRisk.read
    let schemaText = """
        {"type":"object","properties":{
          "path":{"type":"string","description":"File inside the workspace; audio: wav/mp3/flac, video: mp4/mov/webm, images: png/jpg"},
          "prompt":{"type":"string","description":"Question, transcription or translation instruction"}
        },"required":["path","prompt"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let path = call.string("path") else { throw ToolError.missingArgument("path") }
        guard let prompt = call.string("prompt") else { throw ToolError.missingArgument("prompt") }
        let url = try context.workspace.resolve(path, access: .read).url
        let kind: OmniMediaRequest.Kind
        switch url.pathExtension.lowercased() {
        case "wav", "mp3", "flac": kind = .audio
        case "mp4", "mov", "mkv", "webm": kind = .video
        case "png", "jpg", "jpeg", "gif", "bmp": kind = .image
        default: throw ToolError.invalidArguments("Unsupported media extension")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= LocalOmniClient.inputLimit else {
            throw ToolError.fileTooLarge(path, size: size, limit: LocalOmniClient.inputLimit)
        }
        guard let engine = context.mediaEngine else { throw EngineError.notLoaded }
        let data = try Data(contentsOf: url)
        let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                    "gif": "image/gif", "bmp": "image/bmp"][url.pathExtension.lowercased()] ?? "application/octet-stream"
        let result = try await engine.processMedia(OmniMediaRequest(kind: kind, prompt: prompt, data: data, mimeType: mime))
        context.noteRead(url)
        return result.text
    }
}

struct GenerateSpeechTool: AgentTool {
    let name = "generate_speech"
    let summary = "Speak text with the loaded local Omni model and save a WAV file inside the workspace"
    let risk = ToolRisk.write
    let schemaText = """
        {"type":"object","properties":{
          "text":{"type":"string","description":"Text to speak"},
          "path":{"type":"string","description":"New .wav output path inside the workspace"},
          "language":{"type":"string","description":"Speech language code, e.g. en or tr"},
          "voice":{"type":"string","enum":["female","male"]}
        },"required":["text","path"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Generate local speech and save WAV: \(call.string("path") ?? "")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let text = call.string("text"), !text.isEmpty else { throw ToolError.missingArgument("text") }
        guard let path = call.string("path") else { throw ToolError.missingArgument("path") }
        let url = try context.workspace.resolve(path, access: .write).url
        guard url.pathExtension.lowercased() == "wav" else { throw ToolError.invalidArguments("Output must be .wav") }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.invalidArguments("Choose a new WAV path; existing files are preserved")
        }
        guard let engine = context.mediaEngine else { throw EngineError.notLoaded }
        let result = try await engine.processMedia(OmniMediaRequest(kind: .speech, prompt: text, language: call.string("language"), voice: call.string("voice")))
        guard let wav = result.wav else { throw LocalOmniClient.Failure.unavailable("No speech data returned.") }
        try Task.checkCancellation()
        // Resolve again after generation so a changed workspace/symlink cannot redirect the write.
        let destination = try context.workspace.resolve(path, access: .write).url
        guard destination == url else { throw ToolError.pathOutsideWorkspace(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wav.write(to: url, options: .withoutOverwriting)
        context.noteRead(url)
        return "Saved speech: \(path) (\(wav.count) bytes, WAV audio)."
    }
}
