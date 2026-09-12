import AVFoundation
import Foundation
import SwiftData

/// Headless `VoiceInk transcribe` command.
///
/// Runs inside the app binary (`VoiceInk.app/Contents/MacOS/VoiceInk transcribe ...`),
/// so it shares the app's UserDefaults domain (modes, diarization settings),
/// code-signing identity (Keychain access for cloud keys) and bundled resources
/// (Silero VAD model). It never writes to the app's SwiftData stores: the
/// dictionary store is opened read-only for word replacements and custom
/// vocabulary, and results go to output files only — safe to run while the
/// app is transcribing its own queue.
///
/// `--jobs N` transcribes files concurrently. Every worker owns its service
/// registry (the local engines keep per-instance mutable state, so sharing one
/// across concurrent files would corrupt results) and, for whisper, preloads
/// the model once so files reuse the same context instead of reloading per file.
enum TranscribeCommand {

    static func main(arguments: [String]) -> Never {
        // Line-buffer stdout even when redirected to a file or pipe, so
        // progress lines land in logs / `tail -f` in real time instead of
        // flushing in 4KB blocks.
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let code = await run(arguments: arguments)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - Options

    private enum OutputFormat: String, CaseIterable {
        case txt, md, json, srt
    }

    private struct Options {
        var inputs: [URL] = []
        var modeName: String?
        var speakers: TranscribeDiarizationMode?
        var format: OutputFormat = .txt
        var outputDirectory: URL?
        var jobs = 1
        var extensions: Set<String>?
        var recursive = false
        var skipExisting = false
        var jsonOutput = false
        var listModes = false
        var showHelp = false
        var showVersion = false
    }

    // MARK: - Agent-friendly JSON events

    private static let jsonSchemaVersion = "1.0"

    /// Emits one deterministic JSON object per line on stdout (NDJSON).
    /// stdout carries only these events in --json mode; stderr stays free
    /// for human diagnostics, so agents can parse stdout line by line.
    private static func emitEvent(_ event: String, _ fields: [String: Any] = [:]) {
        var object: [String: Any] = ["event": event, "schema_version": jsonSchemaVersion]
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
    }

    private static let helpText = """
        Usage: VoiceInk transcribe [options] <audio files or folders...>

        Transcribes audio/video files headlessly using the app's configuration.
        Folder inputs are expanded to the supported media files inside them.
        Each output file is written as soon as its transcription finishes.

        Options:
          --mode <name>          Mode to use (default: the app's active mode)
          --speakers <mode>      off | auto | voice | stereo
                                 (default: the app's Speakers setting)
          --format <fmt>         txt | md | json | srt  (default: txt)
          -o, --output <dir>     Output directory (default: next to each input)
          --ext <list>           Only pick these extensions when expanding
                                 folders, e.g. --ext mp3,wav
          -r, --recursive        Also scan subfolders of folder inputs
          --skip-existing        Skip inputs whose output file already exists —
                                 makes re-running a big batch resume where it
                                 stopped instead of writing "name 2" duplicates
          -j, --jobs <n>         Transcribe up to n files concurrently (1-8,
                                 default 1). Local engines already use most
                                 cores for a single file, and each extra worker
                                 loads its own copy of the model — best gains
                                 come with cloud models or n of 2-3 locally.
          --json                 Machine-readable mode for scripts and AI
                                 agents: stdout becomes NDJSON — one JSON
                                 event per line (start, file_started,
                                 file_completed, file_failed, warning, error,
                                 done), each with schema_version. Human
                                 diagnostics stay on stderr.
          --list-modes           List available modes and exit
          --version              Print app version and exit
          -h, --help             Show this help

        Exit codes:
          0  success (including "nothing to do")
          1  usage or configuration error
          2  finished, but one or more files failed

        Notes:
          - AI enhancement configured on the mode is skipped in CLI runs.
          - --format json includes utterances and word-level timestamps.
          - srt requires an engine with word timestamps (local whisper,
            Parakeet v2/v3, Nemotron, Apple Speech).
        """

    private static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "--list-modes":
                options.listModes = true
            case "--mode":
                index += 1
                guard index < arguments.count else {
                    throw TranscribeCommandError.usage("--mode requires a value")
                }
                options.modeName = arguments[index]
            case "--speakers":
                index += 1
                guard index < arguments.count,
                    let mode = TranscribeDiarizationMode(rawValue: arguments[index])
                else {
                    throw TranscribeCommandError.usage("--speakers must be one of: off, auto, voice, stereo")
                }
                options.speakers = mode
            case "--format":
                index += 1
                guard index < arguments.count,
                    let format = OutputFormat(rawValue: arguments[index])
                else {
                    throw TranscribeCommandError.usage("--format must be one of: txt, md, json, srt")
                }
                options.format = format
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw TranscribeCommandError.usage("--output requires a value")
                }
                options.outputDirectory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            case "-j", "--jobs":
                index += 1
                guard index < arguments.count, let jobs = Int(arguments[index]), (1...8).contains(jobs) else {
                    throw TranscribeCommandError.usage("--jobs must be a number between 1 and 8")
                }
                options.jobs = jobs
            case "--ext":
                index += 1
                guard index < arguments.count else {
                    throw TranscribeCommandError.usage("--ext requires a value, e.g. --ext mp3,wav")
                }
                let extensions = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
                    .filter { !$0.isEmpty }
                guard !extensions.isEmpty else {
                    throw TranscribeCommandError.usage("--ext requires a value, e.g. --ext mp3,wav")
                }
                options.extensions = Set(extensions)
            case "-r", "--recursive":
                options.recursive = true
            case "--skip-existing":
                options.skipExisting = true
            case "--json":
                options.jsonOutput = true
            case "--version":
                options.showVersion = true
            default:
                if argument.hasPrefix("-") {
                    throw TranscribeCommandError.usage("Unknown option: \(argument)")
                }
                options.inputs.append(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
            }
            index += 1
        }
        return options
    }

    // MARK: - Run

    @MainActor
    private static func run(arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            if arguments.contains("--json") {
                emitEvent("error", ["error": error.localizedDescription])
            } else {
                fputs("error: \(error.localizedDescription)\n\n\(helpText)\n", stderr)
            }
            return 1
        }

        func fail(_ message: String) -> Int32 {
            if options.jsonOutput {
                emitEvent("error", ["error": message])
            } else {
                fputs("error: \(message)\n", stderr)
            }
            return 1
        }
        func warn(_ message: String) {
            if options.jsonOutput {
                emitEvent("warning", ["message": message])
            } else {
                fputs("warning: \(message)\n", stderr)
            }
        }

        if options.showHelp {
            print(helpText)
            return 0
        }

        if options.showVersion {
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            if options.jsonOutput {
                emitEvent("version", ["version": version, "build": build])
            } else {
                print("VoiceInk \(version) (\(build))")
            }
            return 0
        }

        AppDefaults.registerDefaults()

        if options.listModes {
            listModes(json: options.jsonOutput)
            return 0
        }

        guard !options.inputs.isEmpty else {
            return fail("no input files or folders")
        }
        let inputFiles: [URL]
        do {
            inputFiles = try collectInputFiles(
                from: options.inputs,
                extensions: options.extensions,
                recursive: options.recursive,
                quiet: options.jsonOutput
            )
        } catch {
            return fail(error.localizedDescription)
        }
        if let outputDirectory = options.outputDirectory {
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            } catch {
                return fail("cannot create output directory: \(error.localizedDescription)")
            }
        }

        // Bootstrap the same managers the app builds at launch (resolution only —
        // each worker later builds its own engine instances).
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        whisperModelManager.loadAvailableModels()
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // Resolve the mode (explicit name or the app's effective mode).
        let mode: ModeConfig?
        if let modeName = options.modeName {
            guard
                let match = ModeManager.shared.configurations.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(modeName) == .orderedSame
                })
            else {
                return fail("no mode named \"\(modeName)\" — use --list-modes")
            }
            mode = match
        } else {
            mode = nil
        }

        let resolution = ModeRuntimeResolver.transcriptionModelResolution(
            mode: mode, transcriptionModelManager: transcriptionModelManager)
        guard let configuration = ModeRuntimeResolver.transcriptionConfiguration(from: resolution) else {
            return fail(resolutionFailureMessage(resolution))
        }

        let diarizationMode = options.speakers ?? TranscribeDiarizationMode.current
        let wantsSpeakers =
            diarizationMode != .off
            && AudioTranscriptionManager.engineSupportsWordTimings(configuration.model)
        if diarizationMode != .off, !wantsSpeakers {
            warn("\(configuration.model.displayName) produces no word timestamps; transcribing without speakers")
        }
        if configuration.mode.isAIEnhancementEnabled {
            warn("mode has AI enhancement enabled; enhancement is skipped in CLI runs")
        }

        let assignment = assignOutputURLs(
            files: inputFiles,
            format: options.format,
            outputDirectory: options.outputDirectory,
            skipExisting: options.skipExisting
        )
        if assignment.skippedCount > 0, !options.jsonOutput {
            print("skipping \(assignment.skippedCount) file(s) with existing output")
        }
        guard !assignment.jobs.isEmpty else {
            if options.jsonOutput {
                emitEvent("done", ["completed": 0, "failed": 0, "skipped": assignment.skippedCount])
            } else {
                print("nothing to do — every input already has an output file")
            }
            return 0
        }

        let workerCount = min(options.jobs, assignment.jobs.count)
        let isLocalEngine = [.whisper, .fluidAudio, .transcribeCpp, .nativeApple].contains(
            configuration.model.provider)
        if workerCount > 1, isLocalEngine {
            warn(
                "\(workerCount) workers with a local engine — each loads its own model copy (watch RAM); local engines already parallelize one file across cores, so gains are moderate"
            )
        }

        let dictionaryStorage = makeReadOnlyDictionaryStorage()
        if !dictionaryStorage.isReadOnlyStore {
            warn("dictionary store unavailable; word replacements and custom vocabulary disabled")
        }

        if options.jsonOutput {
            emitEvent(
                "start",
                [
                    "mode": configuration.mode.name,
                    "model": configuration.model.displayName,
                    "language": configuration.language,
                    "speakers": diarizationMode.rawValue,
                    "format": options.format.rawValue,
                    "jobs": workerCount,
                    "files": assignment.jobs.count,
                    "skipped": assignment.skippedCount,
                ])
        } else {
            print("mode: \(configuration.mode.name)  model: \(configuration.model.displayName)")
            print(
                "language: \(configuration.language)  speakers: \(diarizationMode.rawValue)  format: \(options.format.rawValue)  jobs: \(workerCount)  files: \(assignment.jobs.count)"
            )
        }

        let jobs = assignment.jobs.enumerated().map { index, pair in
            TranscribeJob(index: index, file: pair.file, outputURL: pair.outputURL)
        }
        let queue = TranscribeJobQueue(jobs: jobs)
        let totalFiles = jobs.count
        let format = options.format
        let jsonOutput = options.jsonOutput

        let failures = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<workerCount {
                group.addTask { @MainActor in
                    await runWorker(
                        queue: queue,
                        totalFiles: totalFiles,
                        configuration: configuration,
                        diarizationMode: diarizationMode,
                        wantsSpeakers: wantsSpeakers,
                        format: format,
                        modelsDirectory: modelsDirectory,
                        dictionaryContainer: dictionaryStorage.container,
                        jsonOutput: jsonOutput
                    )
                }
            }
            var total = 0
            for await workerFailures in group {
                total += workerFailures
            }
            return total
        }

        if options.jsonOutput {
            emitEvent(
                "done",
                [
                    "completed": totalFiles - failures,
                    "failed": failures,
                    "skipped": assignment.skippedCount,
                ])
        } else if failures > 0 {
            fputs("done with \(failures) failure(s)\n", stderr)
        } else {
            print("done")
        }
        return failures > 0 ? 2 : 0
    }

    // MARK: - Worker

    private struct TranscribeJob: Sendable {
        let index: Int
        let file: URL
        let outputURL: URL
    }

    /// Hands one job at a time to whichever worker asks first, so slow files
    /// don't strand a pre-partitioned batch on a single worker.
    private actor TranscribeJobQueue {
        private var jobs: [TranscribeJob]

        init(jobs: [TranscribeJob]) {
            self.jobs = jobs
        }

        func next() -> TranscribeJob? {
            jobs.isEmpty ? nil : jobs.removeFirst()
        }
    }

    /// One worker = one service registry. The local engines keep per-instance
    /// mutable state (whisper context, FluidAudio managers), so instances must
    /// never be shared across concurrently processed files.
    @MainActor
    private static func runWorker(
        queue: TranscribeJobQueue,
        totalFiles: Int,
        configuration: TranscriptionRuntimeConfiguration,
        diarizationMode: TranscribeDiarizationMode,
        wantsSpeakers: Bool,
        format: OutputFormat,
        modelsDirectory: URL,
        dictionaryContainer: ModelContainer,
        jsonOutput: Bool
    ) async -> Int {
        let whisperManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        whisperManager.loadAvailableModels()
        // Preload whisper once so every file in this worker reuses the same
        // context instead of paying a model load per file.
        if configuration.model.provider == .whisper,
            let modelFile = whisperManager.availableModels.first(where: { $0.name == configuration.model.name })
        {
            do {
                try await whisperManager.loadModel(modelFile)
            } catch {
                fputs("warning: model preload failed (\(error.localizedDescription)); loading per file\n", stderr)
            }
        }

        let modelContext = ModelContext(dictionaryContainer)
        let serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperManager,
            modelsDirectory: modelsDirectory,
            modelContext: modelContext
        )

        var failures = 0
        while let job = await queue.next() {
            let position = "[\(job.index + 1)/\(totalFiles)]"
            if jsonOutput {
                emitEvent(
                    "file_started",
                    ["index": job.index + 1, "total": totalFiles, "input": job.file.path])
            } else {
                print("\(position) transcribing \(job.file.lastPathComponent) ...")
            }
            do {
                let result = try await transcribeFile(
                    job.file,
                    configuration: configuration,
                    diarizationMode: diarizationMode,
                    wantsSpeakers: wantsSpeakers,
                    serviceRegistry: serviceRegistry,
                    replacementContext: modelContext
                )
                try writeOutput(
                    result,
                    to: job.outputURL,
                    for: job.file,
                    format: format,
                    configuration: configuration,
                    diarizationMode: diarizationMode
                )
                if jsonOutput {
                    emitEvent(
                        "file_completed",
                        [
                            "index": job.index + 1,
                            "total": totalFiles,
                            "input": job.file.path,
                            "output": job.outputURL.path,
                            "duration_seconds": result.duration,
                            "speakers_detected": Set((result.speakerUtterances ?? []).map(\.speaker)).count,
                        ])
                } else {
                    print("\(position) saved \(job.outputURL.path)")
                }
            } catch {
                failures += 1
                if jsonOutput {
                    emitEvent(
                        "file_failed",
                        [
                            "index": job.index + 1,
                            "total": totalFiles,
                            "input": job.file.path,
                            "error": error.localizedDescription,
                        ])
                } else {
                    fputs("\(position) failed: \(job.file.lastPathComponent): \(error.localizedDescription)\n", stderr)
                }
            }
        }

        await serviceRegistry.cleanup()
        whisperManager.unloadModel()
        return failures
    }

    @MainActor
    private static func listModes(json: Bool) {
        let manager = ModeManager.shared
        let activeId = manager.currentEffectiveConfiguration?.id
        if json {
            let modes = manager.configurations.map { config -> [String: Any] in
                [
                    "name": config.name,
                    "enabled": config.isEnabled,
                    "active": config.id == activeId,
                    "model": config.selectedTranscriptionModelName ?? "",
                ]
            }
            emitEvent("modes", ["modes": modes])
            return
        }
        if manager.configurations.isEmpty {
            print("no modes configured")
            return
        }
        for config in manager.configurations {
            let marker = config.id == activeId ? "*" : " "
            let state = config.isEnabled ? "" : " (disabled)"
            let model = config.selectedTranscriptionModelName ?? "-"
            print("\(marker) \(config.name)\(state)  [\(model)]")
        }
    }

    @MainActor
    private static func resolutionFailureMessage(_ resolution: ModeTranscriptionModelResolution) -> String {
        switch resolution {
        case .noMode:
            return "no enabled mode — configure one in the app or pass --mode"
        case .noSelection(let mode):
            return "mode \"\(mode.name)\" has no transcription model selected"
        case .modelNotFound(let mode):
            return "mode \"\(mode.name)\" references a model that no longer exists"
        case .unavailable(let mode, let model):
            return "model \(model.displayName) (mode \"\(mode.name)\") is not downloaded or has no API key"
        case .available:
            return "unexpected resolution state"
        }
    }

    // MARK: - Transcription core (mirrors AudioTranscriptionManager.processItem, headless)

    private struct FileResult {
        let text: String
        let duration: TimeInterval
        let wordTimings: [WordTiming]?
        let speakerUtterances: [SpeakerUtterance]?
    }

    @MainActor
    private static func transcribeFile(
        _ file: URL,
        configuration: TranscriptionRuntimeConfiguration,
        diarizationMode: TranscribeDiarizationMode,
        wantsSpeakers: Bool,
        serviceRegistry: TranscriptionServiceRegistry,
        replacementContext: ModelContext?
    ) async throws -> FileResult {
        let audioProcessor = AudioProcessor()
        let samples = try await audioProcessor.processAudioToSamples(file)

        let stereoChannels: StereoChannelSamples?
        if wantsSpeakers, diarizationMode == .auto || diarizationMode == .stereo {
            let sourceURL = file
            stereoChannels = await Task.detached(priority: .userInitiated) {
                AudioProcessor().extractStereoChannels(sourceURL)
            }.value
        } else {
            stereoChannels = nil
        }
        if wantsSpeakers, diarizationMode == .stereo, stereoChannels == nil {
            fputs("  note: no distinct stereo channels; skipping speaker separation\n", stderr)
        }

        let runNeuralDiarization =
            wantsSpeakers && (diarizationMode == .voice || (diarizationMode == .auto && stereoChannels == nil))
        let neuralDiarizationTask: Task<[SpeakerSegment], Error>? =
            runNeuralDiarization
            ? Task.detached(priority: .userInitiated) {
                try await SpeakerDiarizationService.shared.diarize(samples: samples)
            }
            : nil
        defer { neuralDiarizationTask?.cancel() }

        let audioAsset = AVURLAsset(url: file)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

        var text: String
        var wordTimings: [WordTiming]?
        var speakerUtterances: [SpeakerUtterance]?
        let temporaryDirectory = FileManager.default.temporaryDirectory

        if let stereoChannels {
            var requestContext = configuration.requestContext
            requestContext.preservesTimeline = true

            let leftURL = temporaryDirectory.appendingPathComponent("voiceink_cli_L_\(UUID().uuidString).wav")
            let rightURL = temporaryDirectory.appendingPathComponent("voiceink_cli_R_\(UUID().uuidString).wav")
            defer {
                try? FileManager.default.removeItem(at: leftURL)
                try? FileManager.default.removeItem(at: rightURL)
            }
            let leftSamples = AudioTranscriptionManager.normalized(stereoChannels.left)
            let rightSamples = AudioTranscriptionManager.normalized(stereoChannels.right)
            try audioProcessor.saveSamplesAsWav(samples: leftSamples, to: leftURL)
            try audioProcessor.saveSamplesAsWav(samples: rightSamples, to: rightURL)

            let leftResult = try await serviceRegistry.transcribeDetailed(
                audioURL: leftURL, model: configuration.model, context: requestContext)
            let rightResult = try await serviceRegistry.transcribeDetailed(
                audioURL: rightURL, model: configuration.model, context: requestContext)

            var merged: [WordTiming] = []
            for var word in AudioTranscriptionManager.wordsWithSignal(leftResult.words ?? [], samples: leftSamples) {
                word.speaker = "1"
                merged.append(word)
            }
            for var word in AudioTranscriptionManager.wordsWithSignal(rightResult.words ?? [], samples: rightSamples) {
                word.speaker = "2"
                merged.append(word)
            }
            merged.sort { $0.start < $1.start }

            if merged.isEmpty {
                text = ""
            } else {
                wordTimings = merged
                let utterances = SpeakerAlignment.channelUtterances(from: merged)
                speakerUtterances = utterances
                text = utterances.map(\.text).joined(separator: " ")
            }
        } else {
            let monoURL = temporaryDirectory.appendingPathComponent("voiceink_cli_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: monoURL) }
            try audioProcessor.saveSamplesAsWav(samples: samples, to: monoURL)

            var requestContext = configuration.requestContext
            requestContext.preservesTimeline = neuralDiarizationTask != nil
            let detailedResult = try await serviceRegistry.transcribeDetailed(
                audioURL: monoURL, model: configuration.model, context: requestContext)
            text = detailedResult.text
            wordTimings = detailedResult.words

            if let neuralDiarizationTask {
                do {
                    let speakerSegments = try await neuralDiarizationTask.value
                    if let words = wordTimings, !words.isEmpty, !speakerSegments.isEmpty {
                        let assigned = SpeakerAlignment.assignSpeakers(words: words, segments: speakerSegments)
                        wordTimings = assigned
                        speakerUtterances = SpeakerAlignment.utterances(from: assigned)
                    }
                } catch {
                    // Diarization failure must not lose the transcription.
                    fputs("  note: diarization failed (\(error.localizedDescription)); keeping plain transcript\n", stderr)
                }
            }
        }

        text = TranscriptionOutputFilter.filter(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.mode.isTextFormattingEnabled {
            text = ParagraphFormatter.format(text)
        }
        if let replacementContext {
            text = WordReplacementService.shared.applyReplacements(to: text, using: replacementContext)
        }

        // Keep the speakers view consistent with the cleaned text, same as the app.
        if var utterances = speakerUtterances {
            for index in utterances.indices {
                var utteranceText = TranscriptionOutputFilter.filter(utterances[index].text)
                if let replacementContext {
                    utteranceText = WordReplacementService.shared.applyReplacements(
                        to: utteranceText, using: replacementContext)
                }
                utterances[index].text = utteranceText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let surviving = utterances.filter { !$0.text.isEmpty }
            speakerUtterances = surviving
            if let words = wordTimings {
                wordTimings = words.filter { word in
                    surviving.contains { utterance in
                        word.speaker == utterance.speaker
                            && word.start >= utterance.start - 0.05
                            && word.end <= utterance.end + 0.05
                    }
                }
            }
        }

        return FileResult(
            text: text,
            duration: duration,
            wordTimings: wordTimings,
            speakerUtterances: speakerUtterances
        )
    }

    // MARK: - Input collection

    /// Expands the mix of file and folder arguments into the final ordered
    /// file list. Folders yield their supported media files (optionally
    /// filtered by `--ext`, optionally recursive); explicit files are taken
    /// as-is after validation. Duplicates (same file reached twice) are dropped.
    private static func collectInputFiles(
        from inputs: [URL], extensions: Set<String>?, recursive: Bool, quiet: Bool = false
    ) throws -> [URL] {
        let fileManager = FileManager.default
        var files: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seenPaths.insert(key).inserted {
                files.append(url)
            }
        }

        for input in inputs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
                throw TranscribeCommandError.usage("file not found: \(input.path)")
            }
            if isDirectory.boolValue {
                let found = try mediaFiles(in: input, extensions: extensions, recursive: recursive)
                guard !found.isEmpty else {
                    let filterNote = extensions.map { " matching --ext \($0.sorted().joined(separator: ","))" } ?? ""
                    throw TranscribeCommandError.usage("no supported media files\(filterNote) in \(input.path)")
                }
                if !quiet {
                    print("folder \(input.path): \(found.count) file(s)")
                }
                found.forEach(append)
            } else {
                guard SupportedMedia.isSupported(url: input) else {
                    throw TranscribeCommandError.usage("unsupported file type: \(input.lastPathComponent)")
                }
                append(input)
            }
        }
        return files
    }

    private static func mediaFiles(in directory: URL, extensions: Set<String>?, recursive: Bool) throws -> [URL] {
        let fileManager = FileManager.default
        var results: [URL] = []

        func isEligible(_ url: URL) -> Bool {
            guard SupportedMedia.isSupported(url: url) else { return false }
            if let extensions {
                return extensions.contains(url.pathExtension.lowercased())
            }
            return true
        }

        if recursive {
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let entry = enumerator?.nextObject() as? URL {
                guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                if isEligible(entry) { results.append(entry) }
            }
        } else {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for entry in contents {
                guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                if isEligible(entry) { results.append(entry) }
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Output rendering

    /// Resolves every output path before processing starts, so concurrent
    /// workers never race on name deduplication. With `skipExisting`, an input
    /// whose natural output (`<basename>.<ext>`) already exists on disk is
    /// dropped instead of being suffixed — re-running a batch resumes it.
    private static func assignOutputURLs(
        files: [URL], format: OutputFormat, outputDirectory: URL?, skipExisting: Bool
    ) -> (jobs: [(file: URL, outputURL: URL)], skippedCount: Int) {
        var usedPaths = Set<String>()
        var jobs: [(file: URL, outputURL: URL)] = []
        var skippedCount = 0
        for file in files {
            let directory = outputDirectory ?? file.deletingLastPathComponent()
            let baseName = file.deletingPathExtension().lastPathComponent
            func candidate(_ name: String) -> URL {
                directory.appendingPathComponent("\(name).\(format.rawValue)")
            }

            if skipExisting,
                !usedPaths.contains(candidate(baseName).path.lowercased()),
                FileManager.default.fileExists(atPath: candidate(baseName).path)
            {
                skippedCount += 1
                continue
            }

            var uniqueName = baseName
            var counter = 2
            while usedPaths.contains(candidate(uniqueName).path.lowercased())
                || FileManager.default.fileExists(atPath: candidate(uniqueName).path)
            {
                uniqueName = "\(baseName) \(counter)"
                counter += 1
            }
            usedPaths.insert(candidate(uniqueName).path.lowercased())
            jobs.append((file, candidate(uniqueName)))
        }
        return (jobs, skippedCount)
    }

    private struct JSONOutput: Codable {
        let file: String
        let durationSeconds: Double
        let mode: String
        let model: String
        let speakers: String
        let text: String
        let utterances: [SpeakerUtterance]?
        let words: [WordTiming]?
    }

    @MainActor
    private static func writeOutput(
        _ result: FileResult,
        to outputURL: URL,
        for file: URL,
        format: OutputFormat,
        configuration: TranscriptionRuntimeConfiguration,
        diarizationMode: TranscribeDiarizationMode
    ) throws {
        // An un-inserted model instance reuses the app's speaker-markdown
        // rendering (including Silence gaps) without touching any store.
        let rendered = Transcription(text: result.text, duration: result.duration)
        rendered.speakerUtterances = result.speakerUtterances
        let speakerMarkdown = rendered.speakerTranscriptMarkdown

        let content: String
        switch format {
        case .txt:
            if let speakerMarkdown {
                content = plainText(fromMarkdown: speakerMarkdown)
            } else {
                content = result.text
            }
        case .md:
            content = "# \(file.lastPathComponent)\n\n\(speakerMarkdown ?? result.text)"
        case .json:
            let payload = JSONOutput(
                file: file.lastPathComponent,
                durationSeconds: result.duration,
                mode: configuration.mode.name,
                model: configuration.model.displayName,
                speakers: diarizationMode.rawValue,
                text: result.text,
                utterances: result.speakerUtterances,
                words: result.wordTimings
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            content = String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"
        case .srt:
            guard let cues = srtCues(from: result) else {
                throw TranscribeCommandError.srtUnavailable
            }
            content = srt(from: cues)
        }

        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func plainText(fromMarkdown markdown: String) -> String {
        let silence = String(localized: "Silence")
        return markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*\(silence)*", with: silence)
    }

    /// SRT cues from utterances, or from words grouped into short cues when
    /// the transcript has timings but no speaker attribution.
    private static func srtCues(from result: FileResult) -> [SpeakerUtterance]? {
        if let utterances = result.speakerUtterances, !utterances.isEmpty {
            return utterances
        }
        guard let words = result.wordTimings, !words.isEmpty else { return nil }
        var cues: [SpeakerUtterance] = []
        var current: SpeakerUtterance?
        var wordCount = 0
        for word in words {
            if var cue = current, wordCount < 10, word.start - cue.end <= 1.0, word.end - cue.start <= 6.0 {
                cue.text += " " + word.text
                cue.end = word.end
                current = cue
                wordCount += 1
            } else {
                if let cue = current { cues.append(cue) }
                current = SpeakerUtterance(speaker: "", text: word.text, start: word.start, end: word.end)
                wordCount = 1
            }
        }
        if let cue = current { cues.append(cue) }
        return cues
    }

    private static func srt(from cues: [SpeakerUtterance]) -> String {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            let label: String
            if cue.speaker.isEmpty {
                label = ""
            } else if Int(cue.speaker) != nil {
                label = "\(String(localized: "Speaker")) \(cue.speaker): "
            } else {
                label = "\(cue.speaker.replacingOccurrences(of: "_", with: " ")): "
            }
            lines.append(String(index + 1))
            lines.append("\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))")
            lines.append("\(label)\(cue.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func srtTimestamp(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let seconds = (totalMilliseconds / 1000) % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    // MARK: - Storage

    /// Opens the app's dictionary store read-only (word replacements + custom
    /// vocabulary). Never touches default.store, so running alongside the app
    /// is safe. Falls back to an empty in-memory store when unavailable —
    /// lookups then simply find nothing.
    private static func makeReadOnlyDictionaryStorage() -> (container: ModelContainer, isReadOnlyStore: Bool) {
        let schema = Schema([VocabularyWord.self, WordReplacement.self])
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        let storeURL = appSupportURL.appendingPathComponent("dictionary.store")

        if FileManager.default.fileExists(atPath: storeURL.path) {
            let configuration = ModelConfiguration(
                "dictionary",
                schema: schema,
                url: storeURL,
                allowsSave: false,
                cloudKitDatabase: .none
            )
            if let container = try? ModelContainer(for: schema, configurations: configuration) {
                return (container, true)
            }
        }

        let memoryConfiguration = ModelConfiguration("dictionary", schema: schema, isStoredInMemoryOnly: true)
        // In-memory container creation cannot realistically fail; crash loudly if it does.
        let container = try! ModelContainer(for: schema, configurations: memoryConfiguration)
        return (container, false)
    }
}

private enum TranscribeCommandError: LocalizedError {
    case usage(String)
    case srtUnavailable

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .srtUnavailable:
            return "SRT output requires word timestamps; this engine provides none"
        }
    }
}
