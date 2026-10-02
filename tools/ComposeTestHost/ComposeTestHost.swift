import AppKit
import CryptoKit
import Foundation
import OSLog
import WebKit

private let testHostLogger = Logger(subsystem: "com.darshshah.Cadence.compose-test-host", category: "SyntheticHost")

private enum SyntheticFixture {
    static let values = [
        "short": "SYNTHETIC alpha 314.",
        "unicode": "SYNTHETIC café 🌿 東京.",
        "multiline": "SYNTHETIC first line.\nSYNTHETIC second line.",
        "partial-prefix": "S"
    ]

    static func summary(_ value: String, secure: Bool = false) -> [String: Any] {
        var remaining = value[...]
        let tokens = values.sorted { $0.value.count > $1.value.count }
        var counts = values.mapValues { _ in 0 }
        while !remaining.isEmpty {
            guard let (name, token) = tokens.first(where: { remaining.hasPrefix($0.value) }) else { break }
            remaining = remaining.dropFirst(token.count)
            counts[name, default: 0] += 1
        }
        let known = remaining.isEmpty
        var result: [String: Any] = [
            "isEmpty": value.isEmpty,
            "utf16Length": value.utf16.count,
            "redacted": secure || !known,
            "containsOnlySyntheticFixtures": known
        ]
        // Never persist arbitrary editor contents, even as hashes. The hash and
        // counts are available only for the published, synthetic fixture set.
        if known && !secure {
            result["sha256"] = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            result["fixtureOccurrences"] = counts
        }
        return result
    }
}

private struct Command: Decodable {
    let schemaVersion: Int
    let id: UUID
    let action: String
    let target: String?
}

@MainActor
private final class CountingTextView: NSTextView {
    var returnCount = 0

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { returnCount += 1 }
        super.keyDown(with: event)
    }
}

@MainActor
private final class FocusableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class TestHost: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSTextFieldDelegate {
    private let directory: URL
    private let instanceID = UUID().uuidString
    private var window: NSWindow?
    private var nativeField = NSTextField()
    private var secureField = NSSecureTextField()
    private var nativeEditor = CountingTextView()
    private var nativeButton = FocusableButton()
    private var webView: WKWebView?
    private var webReady = false
    private var timer: Timer?
    private var busy = false
    private var lastCommandID: UUID?
    private var snapshotSequence = 0
    private var nativeButtonCount = 0
    private var nativeReturnCount = 0
    private var secureReturnCount = 0
    private var webGeneration = 0

    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createWindow()
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCommand() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func createWindow() {
        webGeneration += 1
        webReady = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Compose Test Host — synthetic fixtures only"
        window.identifier = NSUserInterfaceItemIdentifier("compose-test-window")
        window.setAccessibilityIdentifier("compose-test-window")
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let explanation = NSTextField(wrappingLabelWithString: "Development fixture. Use published synthetic text only. Results never contain raw editor values. This app does not contact a provider or access other apps.")
        stack.addArrangedSubview(explanation)
        nativeField = NSTextField()
        nativeField.delegate = self
        nativeField.placeholderString = "Native single-line field"
        nativeField.setAccessibilityIdentifier("native-field")
        nativeField.setAccessibilityLabel("Synthetic native single-line field")
        stack.addArrangedSubview(nativeField)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        nativeEditor = CountingTextView(frame: NSRect(x: 0, y: 0, width: 740, height: 90))
        nativeEditor.isRichText = false
        nativeEditor.isAutomaticQuoteSubstitutionEnabled = false
        nativeEditor.isAutomaticDashSubstitutionEnabled = false
        nativeEditor.isAutomaticTextReplacementEnabled = false
        nativeEditor.setAccessibilityIdentifier("native-editor")
        nativeEditor.setAccessibilityLabel("Synthetic native multiline editor")
        scroll.documentView = nativeEditor
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        stack.addArrangedSubview(scroll)
        secureField = NSSecureTextField()
        secureField.delegate = self
        secureField.placeholderString = "Secure field — insertion must be excluded"
        secureField.setAccessibilityIdentifier("native-secure")
        secureField.setAccessibilityLabel("Synthetic secure field")
        stack.addArrangedSubview(secureField)
        nativeButton = FocusableButton(title: "Ordinary native button", target: self, action: #selector(buttonActivated))
        nativeButton.setAccessibilityIdentifier("native-button")
        stack.addArrangedSubview(nativeButton)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.setAccessibilityIdentifier("web-container")
        stack.addArrangedSubview(web)
        web.heightAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        for child in [explanation, nativeField, scroll, secureField, web] as [NSView] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.window = window
        self.webView = web
        web.loadHTMLString(Self.html, baseURL: nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func buttonActivated() { nativeButtonCount += 1 }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === nativeField { nativeReturnCount += 1 }
            if control === secureField { secureReturnCount += 1 }
        }
        return false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        webReady = true
        if !busy { snapshot(command: nil, status: "ready") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The only page is this bundled string. No external navigation or IO.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func pollCommand() {
        guard !busy else { return }
        let path = directory.appendingPathComponent("command.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
              let data = try? Data(contentsOf: path),
              let command = try? JSONDecoder().decode(Command.self, from: data),
              command.id != lastCommandID else { return }
        lastCommandID = command.id
        busy = true
        guard command.schemaVersion == 1 else { snapshot(command: command, status: "invalid-command"); return }
        switch command.action {
        case "snapshot": snapshot(command: command)
        case "reset":
            guard window?.isVisible == true && webReady else { snapshot(command: command, status: "not-ready"); return }
            window?.makeFirstResponder(nil)
            nativeField.stringValue = ""
            secureField.stringValue = ""
            nativeEditor.string = ""
            nativeEditor.returnCount = 0
            nativeButtonCount = 0
            nativeReturnCount = 0
            secureReturnCount = 0
            webView?.evaluateJavaScript("window.testHost.reset()") { [weak self] _, error in
                self?.snapshot(command: command, status: error == nil ? "ok" : "web-error")
            }
        case "focus": focus(command)
        case "close-window":
            window?.close()
            snapshot(command: command)
        case "reopen-window":
            guard window?.isVisible != true else { snapshot(command: command, status: "already-open"); return }
            createWindow()
            // Return a pending acknowledgement. A subsequent snapshot reports
            // webReady; the controller waits for it before resetting/focusing.
            snapshot(command: command, status: "loading")
        case "quit":
            snapshot(command: command) { NSApplication.shared.terminate(nil) }
        default: snapshot(command: command, status: "invalid-command")
        }
    }

    private func focus(_ command: Command) {
        guard let window, window.isVisible, webReady else { snapshot(command: command, status: "not-ready"); return }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        switch command.target {
        case "native-field":
            window.makeFirstResponder(nativeField)
            nativeField.currentEditor()?.selectedRange = NSRange(location: nativeField.stringValue.utf16.count, length: 0)
        case "native-editor":
            window.makeFirstResponder(nativeEditor)
            nativeEditor.setSelectedRange(NSRange(location: nativeEditor.string.utf16.count, length: 0))
        case "native-secure": window.makeFirstResponder(secureField)
        case "native-button": window.makeFirstResponder(nativeButton)
        case "web-textarea", "web-contenteditable", "web-button", "web-cursor-button":
            guard let target = command.target else { return }
            window.makeFirstResponder(webView)
            webView?.evaluateJavaScript("window.testHost.focus('\(target)')") { [weak self] _, error in
                self?.snapshot(command: command, status: error == nil ? "ok" : "web-error")
            }
            return
        default: snapshot(command: command, status: "invalid-target"); return
        }
        snapshot(command: command)
    }

    private func snapshot(command: Command?, status: String = "ok", completion: (() -> Void)? = nil) {
        busy = true
        let generation = webGeneration
        guard let webView, webReady else {
            writeSnapshot(command: command, status: status, web: nil)
            completion?()
            return
        }
        webView.evaluateJavaScript("window.testHost.snapshot()") { [weak self] result, error in
            guard let self else { return }
            guard self.webGeneration == generation else {
                self.writeSnapshot(command: command, status: "window-changed", web: nil)
                completion?()
                return
            }
            self.writeSnapshot(command: command, status: error == nil ? status : "web-error", web: result as? [String: Any])
            completion?()
        }
    }

    private func writeSnapshot(command: Command?, status: String, web: [String: Any]?) {
        var fields: [String: Any] = [
            "native-field": SyntheticFixture.summary(nativeField.currentEditor()?.string ?? nativeField.stringValue),
            "native-editor": SyntheticFixture.summary(nativeEditor.string),
            "native-secure": SyntheticFixture.summary(secureField.currentEditor()?.string ?? secureField.stringValue, secure: true)
        ]
        for id in ["web-textarea", "web-contenteditable", "web-cursor-button"] {
            if let value = (web?["values"] as? [String: String])?[id] {
                fields[id] = SyntheticFixture.summary(value)
            }
        }
        snapshotSequence += 1
        var state: [String: Any] = [
            "schemaVersion": 1, "syntheticOnly": true,
            "instanceID": instanceID, "processID": ProcessInfo.processInfo.processIdentifier,
            "sequence": snapshotSequence, "windowGeneration": webGeneration,
            "status": status, "webReady": webReady,
            "windowVisible": window?.isVisible == true,
            "applicationActive": NSApplication.shared.isActive,
            "fields": fields,
            "nativeButtonActivationCount": nativeButtonCount,
            "nativeFieldReturnCount": nativeReturnCount,
            "nativeEditorReturnCount": nativeEditor.returnCount,
            "secureFieldReturnCount": secureReturnCount,
            "webReturnCounts": web?["returnCounts"] ?? [:],
            "webButtonActivationCount": web?["buttonActivationCount"] ?? 0,
            "webDocumentFocused": web?["documentFocused"] ?? false,
            "webFocusedID": web?["focusedID"] ?? ""
        ]
        if let commandID = command?.id ?? lastCommandID { state["commandID"] = commandID.uuidString }
        let first = window?.firstResponder
        if first === nativeEditor { state["nativeFocusedID"] = "native-editor" }
        else if first === nativeButton { state["nativeFocusedID"] = "native-button" }
        else if nativeField.currentEditor() === first, first != nil { state["nativeFocusedID"] = "native-field" }
        else if secureField.currentEditor() === first, first != nil { state["nativeFocusedID"] = "native-secure" }
        else { state["nativeFocusedID"] = "" }
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            let output = directory.appendingPathComponent("state.json")
            try data.write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        } catch {
            testHostLogger.error("Synthetic host could not persist a state snapshot")
        }
        busy = false
    }

    private static let html = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'">
    <style>body{font:14px system-ui;margin:12px;background:#fafafa;color:#222}label{display:block;margin-top:8px}textarea,[contenteditable],.cursor-text{box-sizing:border-box;display:block;width:100%;min-height:45px;border:1px solid #aaa;background:white;padding:7px;font:14px system-ui;white-space:pre-wrap}.cursor-text{cursor:text}button{margin-top:8px}</style></head><body>
    <label for="web-textarea">Synthetic WebKit textarea</label><textarea id="web-textarea" aria-label="Synthetic WebKit textarea" spellcheck="false"></textarea>
    <label id="editor-label">Synthetic WebKit contenteditable</label><div id="web-contenteditable" contenteditable="true" role="textbox" aria-labelledby="editor-label" spellcheck="false"></div>
    <button id="web-button" type="button">Ordinary web button</button>
    <label id="cursor-label">Synthetic button-role editor with text-cursor hint</label><div id="web-cursor-button" role="button" tabindex="0" class="cursor-text" aria-labelledby="cursor-label"></div>
    <script>
    (() => {
      const ids = ['web-textarea','web-contenteditable','web-cursor-button'];
      let returnCounts = Object.fromEntries(ids.map(id => [id,0]));
      let buttonActivationCount = 0;
      const cursor = document.getElementById('web-cursor-button');
      document.getElementById('web-button').addEventListener('click', () => buttonActivationCount++);
      document.addEventListener('keydown', event => {
        const id = document.activeElement.id;
        if (ids.includes(id) && event.key === 'Enter') returnCounts[id]++;
        if (id !== cursor.id || event.metaKey || event.ctrlKey || event.altKey) return;
        if (event.key === 'Enter') { event.preventDefault(); cursor.textContent += '\n'; }
        else if (event.key === 'Backspace') { event.preventDefault(); cursor.textContent = [...cursor.textContent].slice(0,-1).join(''); }
        else if ([...event.key].length === 1) { event.preventDefault(); cursor.textContent += event.key; }
      });
      window.testHost = {
        reset() { ids.forEach(id => { const node=document.getElementById(id); if(id==='web-textarea')node.value=''; else node.textContent=''; }); returnCounts=Object.fromEntries(ids.map(id=>[id,0])); buttonActivationCount=0; document.activeElement.blur(); },
        focus(id) { const node=document.getElementById(id); node.focus(); if(id==='web-textarea')node.setSelectionRange(node.value.length,node.value.length); if(id==='web-contenteditable'){const range=document.createRange();range.selectNodeContents(node);range.collapse(false);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);} },
        snapshot() { return { values:Object.fromEntries(ids.map(id=>[id,id==='web-textarea'?document.getElementById(id).value:document.getElementById(id).innerText])), returnCounts, buttonActivationCount, focusedID:document.activeElement.id, documentFocused:document.hasFocus() }; }
      };
    })();
    </script></body></html>
    """#
}

@main
private enum Main {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments == [arguments[0], "--self-test"] {
            let value = SyntheticFixture.values["short"]!
            let twice = SyntheticFixture.summary(value + value)
            precondition((twice["fixtureOccurrences"] as? [String: Int])?["short"] == 2)
            precondition(twice["sha256"] != nil)
            precondition(SyntheticFixture.summary("not a fixture")["sha256"] == nil)
            precondition(SyntheticFixture.summary(value, secure: true)["sha256"] == nil)
            precondition(SyntheticFixture.summary(SyntheticFixture.values["unicode"]!)["containsOnlySyntheticFixtures"] as? Bool == true)
            precondition((SyntheticFixture.summary("S")["fixtureOccurrences"] as? [String: Int])?["partial-prefix"] == 1)
            FileHandle.standardOutput.write(Data("{\"status\":\"passed\",\"scope\":\"synthetic-summary-only\"}\n".utf8))
            return
        }
        guard arguments.count == 3, arguments[1] == "--control-directory" else {
            FileHandle.standardError.write(Data("Usage: ComposeTestHost --control-directory /absolute/private/run-directory\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        guard arguments[2].hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true else {
            FileHandle.standardError.write(Data("Control directory must be empty, owned by this user, and have mode 0700.\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = TestHost(directory: directory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
