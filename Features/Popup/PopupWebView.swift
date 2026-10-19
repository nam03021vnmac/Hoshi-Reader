//
//  PopupWebView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import WebKit

class AudioHandler: NSObject, WKURLSchemeHandler {
    private var tasks = Set<ObjectIdentifier>()
    
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestUrl = task.request.url,
              let components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false),
              let targetUrlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetUrl = URL(string: targetUrlString) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        
        let taskId = ObjectIdentifier(task)
        tasks.insert(taskId)
        
        Task {
            do {
                let request = URLRequest(url: targetUrl, timeoutInterval: 4)
                let (data, _) = try await URLSession.shared.data(for: request)
                
                await MainActor.run {
                    guard self.tasks.contains(taskId) else { return }
                    
                    let response = HTTPURLResponse(
                        url: requestUrl,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Access-Control-Allow-Origin": "*",
                            "Content-Type": "application/json"
                        ]
                    )!
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                }
            } catch {
                await MainActor.run {
                    guard self.tasks.contains(taskId) else { return }
                    task.didFailWithError(error)
                }
            }
        }
    }
    
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        tasks.remove(ObjectIdentifier(task))
    }
}

class ImageHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestUrl = task.request.url,
              let components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false),
              let dictionary = components.queryItems?.first(where: { $0.name == "dictionary" })?.value,
              let mediaPath = components.queryItems?.first(where: { $0.name == "path" })?.value else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        
        LookupEngine.shared.withMediaFile(dictName: dictionary, mediaPath: mediaPath) { data in
            let mime = mimeType(for: mediaPath)
            Task { @MainActor in
                guard !data.isEmpty else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                
                let response = URLResponse(
                    url: requestUrl,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }
    
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    
    private func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

class DocumentResourceHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        
        let fileName = url.deletingPathExtension().lastPathComponent
        do {
            guard let fontFile = try FontManager.shared.fontUrl(name: fileName, verticalWriting: false) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            
            let data = try Data(contentsOf: fontFile, options: .mappedIfSafe)
            let response = URLResponse(
                url: url,
                mimeType: mimeType(for: fontFile),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "font/ttf"
        }
    }
}

/// One of the native buttons that popup.js reserves space for with a `.button-slot` span.
struct PopupButtonSlot {
    let kind: String
    let entryIndex: Int
    let slotIndex: Int
    let frame: CGRect
    let state: String
    let isEnabled: Bool

    var key: String {
        "\(kind)-\(entryIndex)-\(slotIndex)"
    }

    init?(_ rect: [String: Any]) {
        guard let kind = rect["kind"] as? String,
              let entryIndex = rect["entryIndex"] as? Int,
              let x = rect["x"] as? CGFloat,
              let y = rect["y"] as? CGFloat,
              let width = rect["width"] as? CGFloat,
              let height = rect["height"] as? CGFloat,
              width > 0, height > 0 else {
            return nil
        }

        let slotIndex = rect["slotIndex"] as? Int ?? 0
        if kind != "audio", !AnkiManager.shared.cardFormats.indices.contains(slotIndex) {
            return nil
        }
        self.kind = kind
        self.entryIndex = entryIndex
        self.slotIndex = slotIndex
        self.frame = CGRect(x: x, y: y, width: width, height: height)
        self.state = rect["state"] as? String ?? "default"
        self.isEnabled = rect["enabled"] as? Bool ?? true
    }
}

/// The popup's WKWebView. The platform glue (UIViewRepresentable / NSViewRepresentable and
/// the native buttons over each `.button-slot`) lives in PopupWebView+iOS.swift and PopupWebView+macOS.swift.
struct PopupWebView {
    let content: String
    let position: CGPoint
    var scale: CGFloat = 1.0
    var clearSelection: Bool
    var dictionaryStyles: [String: String] = [:]
    var lookupEntries: [[String: Any]] = []
    var scanNonJapaneseText: Bool = true
    var scanLength: Int = 16
    var backTrigger: Bool = false
    var forwardTrigger: Bool = false
    var onMine: (([String: String], UUID) async -> Bool)? = nil
    var onTextSelected: ((SelectionData) -> Int?)? = nil
    var onTapOutside: (() -> Void)? = nil
    var onSwipeDismiss: (() -> Void)? = nil
    var onRedirect: ((String) -> [[String: Any]])? = nil
    var onKanjiRedirect: ((String) -> [String: Any]?)? = nil
    var scrollViewBounces: Bool = false
    var onScrollViewOffsetChanged: ((CGFloat) -> Void)? = nil
    var onScrollViewWillBeginDragging: (() -> Void)? = nil
    var onScrollViewDidEndDragging: (() -> Void)? = nil
    var onScrollViewDidEndDecelerating: (() -> Void)? = nil

    private static let swipeDismissJs = """
    (function() {
        if (!window.swipeThreshold) {
            return;
        }
        var startX, startY;
        document.addEventListener('touchstart', function(e) {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
        });
        document.addEventListener('touchend', function(e) {
            var dx = e.changedTouches[0].clientX - startX;
            var dy = e.changedTouches[0].clientY - startY;
            var hasSelection = window.getSelection().toString();

            if (Math.abs(dx) > window.swipeThreshold && Math.abs(dy) < 30 && !hasSelection) {
                webkit.messageHandlers.swipeDismiss.postMessage(null);
            }
        });
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeConfiguration(coordinator: Coordinator) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "openLink")
        config.userContentController.add(coordinator, name: "textSelected")
        config.userContentController.add(coordinator, name: "tapOutside")
        config.userContentController.add(coordinator, name: "swipeDismiss")
        config.userContentController.add(coordinator, name: "playWordAudio")
        config.userContentController.add(coordinator, name: "buttonRects")
        config.userContentController.add(coordinator, name: "showNotes")
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "mineEntry")
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "duplicateCheck")
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "getEntries")
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "lookupRedirect")
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "kanjiRedirect")
        config.setURLSchemeHandler(AudioHandler(), forURLScheme: "audio")
        config.setURLSchemeHandler(ImageHandler(), forURLScheme: "image")
        config.setURLSchemeHandler(DocumentResourceHandler(), forURLScheme: "local-resources")
        config.mediaTypesRequiringUserActionForPlayback = []
        return config
    }

    func updateWebView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        if !coordinator.wasLoaded {
            coordinator.currentContent = content
            coordinator.wasLoaded = true
            let html = constructHtml(content: content)
            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }

        if coordinator.clearSelection != clearSelection {
            coordinator.clearSelection = clearSelection
            webView.evaluateJavaScript("window.hoshiSelection.clearSelection()")
        }

        if coordinator.lastBackTrigger != backTrigger {
            coordinator.lastBackTrigger = backTrigger
            webView.evaluateJavaScript("window.navigateBack()")
        }

        if coordinator.lastForwardTrigger != forwardTrigger {
            coordinator.lastForwardTrigger = forwardTrigger
            webView.evaluateJavaScript("window.navigateForward()")
        }
    }

    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.removeWordAddedObserver()
        Task {
            await WordAudioPlayer.shared.stop(id: coordinator.id)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "openLink")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "textSelected")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tapOutside")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "swipeDismiss")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playWordAudio")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "buttonRects")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "showNotes")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mineEntry", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "duplicateCheck", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "getEntries", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lookupRedirect", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kanjiRedirect", contentWorld: .page)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        var parent: PopupWebView
        var currentContent: String = ""
        var wasLoaded: Bool = false
        var clearSelection: Bool = false
        var lastBackTrigger: Bool = false
        var lastForwardTrigger: Bool = false
        var entries: [[String: Any]] = []
        weak var webView: WKWebView?
        lazy var buttons = PopupButtons(coordinator: self)
        private var wordAddedObserver: NSObjectProtocol?
        let id = UUID()

        init(parent: PopupWebView) {
            self.parent = parent
            super.init()
            wordAddedObserver = NotificationCenter.default.addObserver(
                forName: AnkiManager.wordAddedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.webView?.evaluateJavaScript("recheckDuplicates()")
                }
            }
        }

        func removeWordAddedObserver() {
            if let wordAddedObserver {
                NotificationCenter.default.removeObserver(wordAddedObserver)
                self.wordAddedObserver = nil
            }
        }

        /// The SF Symbol drawn on a slot's button, and the point size to draw it at.
        func symbol(for slot: PopupButtonSlot) -> (name: String, pointSize: CGFloat)? {
            let pointSize = 13 * parent.scale
            if slot.kind == "audio" {
                return (slot.state == "error" ? "speaker.slash" : "speaker.wave.2", pointSize)
            }
            if slot.kind == "note" {
                return ("magnifyingglass", 9 * parent.scale)
            }
            guard AnkiManager.shared.cardFormats.indices.contains(slot.slotIndex) else { return nil }
            var icon = AnkiManager.shared.cardFormats[slot.slotIndex].icon
            let isSmall = icon.hasSuffix(".small")
            if isSmall {
                icon = String(icon.dropLast(".small".count))
            }
            let name = slot.state == "duplicate" ? (AnkiCardFormat.duplicateIcons[icon] ?? icon) : icon
            return (name, isSmall ? 10 * parent.scale : pointSize)
        }

        /// The audio sources for an entry, and the index of the one that is selected (-1 if none).
        func audioMenu(entryIndex: Int) async -> (names: [String], selected: Int) {
            let result = try? await webView?.callAsyncJavaScript(
                "return await getAudioMenu(entryIndex);",
                arguments: ["entryIndex": entryIndex],
                in: nil,
                contentWorld: .page
            )
            let menu = result as? [String: Any]
            return (menu?["names"] as? [String] ?? [], menu?["selected"] as? Int ?? -1)
        }

        func playAudio(entryIndex: Int, sourceIndex: Int) {
            webView?.evaluateJavaScript("playEntryAudio(\(entryIndex), \(sourceIndex))")
        }

        func buttonTapped(kind: String, entryIndex: Int, slotIndex: Int) {
            switch kind {
            case "audio":
                webView?.evaluateJavaScript("playEntryAudio(\(entryIndex))")
            case "note":
                webView?.evaluateJavaScript("showNotesAtIndex(\(entryIndex), \(slotIndex))")
            default:
                webView?.evaluateJavaScript("mineEntryAtIndex(\(entryIndex), \(slotIndex))")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            entries = parent.lookupEntries
            webView.callAsyncJavaScript(
                """
                window.dictionaryStyles = dictionaryStyles;
                window.entryCount = entryCount;
                window.renderPopup();
                """,
                arguments: [
                    "dictionaryStyles": parent.dictionaryStyles,
                    "entryCount": entries.count,
                ],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            if message.name == "mineEntry", let content = message.body as? [String: String] {
                guard let slotIndex = content["slotIndex"].flatMap(Int.init),
                      AnkiManager.shared.cardFormats.indices.contains(slotIndex) else {
                    return (false, nil)
                }
                return (await parent.onMine?(content, AnkiManager.shared.cardFormats[slotIndex].id) ?? false, nil)
            }
            if message.name == "duplicateCheck", let fields = message.body as? [String: String] {
                return (await AnkiManager.shared.checkDuplicates(fields: fields), nil)
            }
            if message.name == "getEntries", let body = message.body as? [String: Any] {
                let start = body["start"] as? Int ?? 0
                let count = body["count"] as? Int ?? 0
                return (Array(entries[start..<start + count]), nil)
            }
            if message.name == "lookupRedirect", let query = message.body as? String {
                entries = parent.onRedirect?(query) ?? []
                return (entries.count, nil)
            }
            if message.name == "kanjiRedirect", let kanji = message.body as? String {
                return (parent.onKanjiRedirect?(kanji) ?? nil, nil)
            }
            return (nil, nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "openLink", let urlString = message.body as? String,
               let url = URL(string: urlString) {
                Platform.open(url)
            }
            else if message.name == "tapOutside" {
                parent.onTapOutside?()
                message.webView?.evaluateJavaScript("window.hoshiSelection.clearSelection()")
            }
            else if message.name == "swipeDismiss" {
                parent.onSwipeDismiss?()
            }
            else if message.name == "buttonRects",
                    let rects = message.body as? [[String: Any]] {
                guard let webView = message.webView else { return }
                buttons.update(rects.compactMap(PopupButtonSlot.init), in: webView)
            }
            else if message.name == "showNotes", let fields = message.body as? [String: String],
                    let slotIndex = fields["slotIndex"].flatMap(Int.init) {
                Task { await AnkiManager.shared.showNotes(fields: fields, formatIndex: slotIndex) }
            }
            else if message.name == "textSelected" {
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let sentence = body["sentence"] as? String,
                      let rectData = body["rect"] as? [String: Any],
                      let x = rectData["x"] as? CGFloat,
                      let y = rectData["y"] as? CGFloat,
                      let w = rectData["width"] as? CGFloat,
                      let h = rectData["height"] as? CGFloat else {
                    return
                }
                let contentOrigin = message.webView.map(contentOrigin(of:)) ?? .zero
                let rect = CGRect(
                    x: parent.position.x + x + contentOrigin.x,
                    y: parent.position.y + y + contentOrigin.y,
                    width: w,
                    height: h
                )
                let clozeOffset = body["clozeOffset"] as? Int
                let selectionData = SelectionData(text: text, sentence: sentence, rect: rect, clozeOffset: clozeOffset)

                if let highlightCount = parent.onTextSelected?(selectionData) {
                    message.webView?.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(highlightCount))")
                }
            }
            else if message.name == "playWordAudio",
                    let content = message.body as? [String: Any],
                    let urlString = content["url"] as? String {
                let requestedMode = (content["mode"] as? String).flatMap(AudioPlaybackMode.init) ?? .interrupt
                Task(priority: .userInitiated) {
                    await WordAudioPlayer.shared.play(urlString: urlString, requestedMode: requestedMode, id: self.id)
                }
            }
        }
    }

    private func constructHtml(content: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <link rel="stylesheet" href="popup.css">
            <style>
                \(FontManager.shared.fontfaceCSS)
                html, body { --popup-scale: \(scale); }
            </style>
            <script>
                window.scanNonJapaneseText = \(scanNonJapaneseText);
                window.scanLength = \(scanLength);
            </script>
            <script src="selection.js"></script>
            <script src="popup.js"></script>
        </head>
        <body>
            \(content)
            <script>\(Self.swipeDismissJs)</script>
            <div class="overlay">
                <div class="overlay-close" onclick="closeOverlay()">×</div>
                <div class="overlay-content"></div>
            </div>
        </body>
        </html>
        """
    }
}
