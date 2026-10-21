import AppKit
import UniformTypeIdentifiers
import WebKit

/// Hosts the bundled Filerobot Image Editor.  The editor itself is completely
/// local: the HTML, JavaScript, translations and source image are all loaded
/// from the application bundle or from memory.
final class FilerobotImageEditorViewController: NSViewController {
    private let sourceImage: CGImage
    private let webView: WKWebView

    init(image: CGImage) {
        sourceImage = image

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(nibName: nil, bundle: nil)
        configuration.userContentController.add(self, name: "captures")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "captures")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let toolbar = NSVisualEffectView()
        toolbar.material = .sidebar
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active

        let title = NSTextField(labelWithString: Localization.string("Image Editor"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor

        let ocrButton = makeButton(
            title: Localization.string("OCR"),
            action: #selector(runOCR)
        )
        let copyButton = makeButton(
            title: Localization.string("Copy"),
            action: #selector(copyEditedImage)
        )

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, spacer, ocrButton, copyButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        webView.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(toolbar)
        rootView.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: rootView.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        view = rootView
        loadLocalEditor()
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        return button
    }

    private func loadLocalEditor() {
        guard let url = Bundle.main.url(
            forResource: "all-in-one-prototype",
            withExtension: "html"
        ) else {
            showError("Unable to load the local image editor.")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    @objc private func runOCR() {
        requestCurrentImage(action: "ocr")
    }

    @objc private func copyEditedImage() {
        requestCurrentImage(action: "copy")
    }

    private func requestCurrentImage(action: String) {
        webView.evaluateJavaScript("window.CapturesImageEditor && window.CapturesImageEditor.exportCurrent('\\(action)');") { _, error in
            if error != nil {
                self.showError("Unable to prepare edited image.")
            }
        }
    }

    private func injectSourceImage() {
        let bitmap = NSBitmapImageRep(cgImage: sourceImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            showError("Unable to prepare edited image.")
            return
        }

        // JSON-encode the data URL rather than interpolating it into JavaScript.
        // It prevents the image data from being interpreted as source code.
        let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"
        guard
            let encoded = try? JSONSerialization.data(withJSONObject: [dataURL]),
            let jsonArray = String(data: encoded, encoding: .utf8)
        else {
            showError("Unable to prepare edited image.")
            return
        }
        // The All-in-One page loads the local editor bundle asynchronously. Retry
        // briefly so the native capture never races that local script load.
        let script = """
        (() => {
          const source = \(jsonArray)[0];
          const open = () => {
            if (window.CapturesImageEditor && window.CapturesImageEditor.open) {
              window.CapturesImageEditor.open(source);
            } else {
              window.setTimeout(open, 50);
            }
          };
          open();
        })();
        """
        webView.evaluateJavaScript(script) { _, error in
            if error != nil {
                self.showError("Unable to load the local image editor.")
            }
        }
    }

    private func receiveEditedImage(action: String, dataURL: String, name: String?, extension fileExtension: String?) {
        guard let imageData = data(from: dataURL) else {
            showError("Unable to prepare edited image.")
            return
        }

        switch action {
        case "save":
            save(imageData, suggestedName: name, fileExtension: fileExtension)
        case "copy", "ocr":
            guard let image = cgImage(from: imageData) else {
                showError("Unable to prepare edited image.")
                return
            }
            if action == "copy" {
                _ = PasteboardHelper.copyImage(
                    image,
                    showsConfirmation: true,
                    confirmationScreen: view.window?.screen
                )
            } else {
                AnnotationEditorWindow.open(with: image, mode: .ocr)
            }
        default:
            break
        }
    }

    private func save(_ imageData: Data, suggestedName: String?, fileExtension: String?) {
        let extensionValue = normalizedExtension(fileExtension)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(normalizedName(suggestedName)).\(extensionValue)"

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try imageData.write(to: destination, options: .atomic)
        } catch {
            showError("Save Failed")
        }
    }

    private func data(from dataURL: String) -> Data? {
        guard let separator = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...]))
    }

    private func cgImage(from data: Data) -> CGImage? {
        guard let image = NSImage(data: data) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func normalizedName(_ value: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
        let fallback = Localization.string("Screenshot")
        let name = (value ?? fallback).unicodeScalars.filter(allowed.contains).map(String.init).joined()
        return name.isEmpty ? fallback : name
    }

    private func normalizedExtension(_ value: String?) -> String {
        switch value?.lowercased() {
        case "jpg", "jpeg": return "jpg"
        case "webp": return "webp"
        default: return "png"
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Localization.string("Image Editor")
        alert.informativeText = Localization.string(message)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension FilerobotImageEditorViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectSourceImage()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError("Unable to load the local image editor.")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError("Unable to load the local image editor.")
    }
}

extension FilerobotImageEditorViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.allowedContentTypes = [.image]

        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

extension FilerobotImageEditorViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == "captures",
            let payload = message.body as? [String: Any],
            let action = payload["action"] as? String,
            let dataURL = payload["dataURL"] as? String
        else { return }

        receiveEditedImage(
            action: action,
            dataURL: dataURL,
            name: payload["name"] as? String,
            extension: payload["extension"] as? String
        )
    }
}
