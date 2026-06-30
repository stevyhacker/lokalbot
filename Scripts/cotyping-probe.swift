import AppKit
import Foundation

struct ProbeConfig {
    enum InputMode: String {
        case direct
        case events
    }

    var prompt: String = ""
    var slug: String = "probe"
    var outputDirectory: URL = URL(fileURLWithPath: "/tmp/cotyping-probe")
    var typeDelay: TimeInterval = 0.025
    var waitSeconds: TimeInterval = 5
    var inputMode: InputMode = .direct

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let nextIndex = index + 1
            switch argument {
            case "--prompt" where nextIndex < arguments.count:
                prompt = arguments[nextIndex]
                index += 2
            case "--slug" where nextIndex < arguments.count:
                slug = arguments[nextIndex]
                index += 2
            case "--output-dir" where nextIndex < arguments.count:
                outputDirectory = URL(fileURLWithPath: arguments[nextIndex])
                index += 2
            case "--type-delay" where nextIndex < arguments.count:
                typeDelay = TimeInterval(arguments[nextIndex]) ?? typeDelay
                index += 2
            case "--wait" where nextIndex < arguments.count:
                waitSeconds = TimeInterval(arguments[nextIndex]) ?? waitSeconds
                index += 2
            case "--input-mode" where nextIndex < arguments.count:
                inputMode = InputMode(rawValue: arguments[nextIndex]) ?? inputMode
                index += 2
            default:
                fputs("Unknown or incomplete argument: \(argument)\n", stderr)
                exit(64)
            }
        }

        guard !prompt.isEmpty else {
            fputs("--prompt is required\n", stderr)
            exit(64)
        }
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    private let config: ProbeConfig
    private let textView = NSTextView(frame: .zero)
    private var window: NSWindow?

    init(config: ProbeConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(
                at: config.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("Could not create output directory: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let windowFrame = NSRect(x: 260, y: 260, width: 900, height: 360)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cotyping Probe - \(config.slug)"
        window.isReleasedWhenClosed = false

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: 28)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = ""

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        window.contentView = scrollView

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.typeNextCharacter(at: self.config.prompt.startIndex)
        }
    }

    private func typeNextCharacter(at index: String.Index) {
        guard index < config.prompt.endIndex else {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.waitSeconds) {
                self.captureAndFinish()
            }
            return
        }

        let character = String(config.prompt[index])
        switch config.inputMode {
        case .direct:
            textView.insertText(character, replacementRange: NSRange(location: textView.string.count, length: 0))
            textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))
        case .events:
            postKeyboardCharacter(character)
        }
        let nextIndex = config.prompt.index(after: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + config.typeDelay) {
            self.typeNextCharacter(at: nextIndex)
        }
    }

    private func captureAndFinish() {
        writeTextFile(name: "\(config.slug).txt", contents: config.prompt)
        writeTextFile(name: "\(config.slug).document.txt", contents: textView.string)

        guard let captureRect = captureRect() else {
            fputs("Could not determine capture rect\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let rectString = "\(Int(captureRect.origin.x)),\(Int(captureRect.origin.y)),\(Int(captureRect.width)),\(Int(captureRect.height))"
        writeTextFile(name: "\(config.slug).rect", contents: rectString)

        let imageURL = config.outputDirectory.appendingPathComponent("\(config.slug).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", imageURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                fputs("screencapture exited with \(process.terminationStatus)\n", stderr)
            }
        } catch {
            fputs("Could not run screencapture: \(error)\n", stderr)
        }

        print(config.outputDirectory.path)
        NSApp.terminate(nil)
    }

    private func captureRect() -> NSRect? {
        guard let window else { return nil }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return nil }

        let margin: CGFloat = 120
        let x = max(screen.frame.minX, frame.minX - margin)
        let topY = screen.frame.maxY - frame.maxY - margin
        let y = max(0, topY)
        let maxWidth = screen.frame.maxX - x
        let maxHeight = screen.frame.height - y
        let width = min(frame.width + margin * 2, maxWidth)
        let height = min(frame.height + margin * 2, maxHeight)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func writeTextFile(name: String, contents: String) {
        let url = config.outputDirectory.appendingPathComponent(name)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fputs("Could not write \(url.path): \(error)\n", stderr)
        }
    }

    private func postKeyboardCharacter(_ character: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var utf16 = Array(character.utf16)
        guard !utf16.isEmpty else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.post(tap: .cghidEventTap)
    }
}

let config = ProbeConfig(arguments: CommandLine.arguments)
let app = NSApplication.shared
let delegate = ProbeAppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
