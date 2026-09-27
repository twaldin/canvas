import AppKit
import CanvasCore
import UniformTypeIdentifiers

/// Sharing what's on the board: the selection as a picture (drawn by `view.render`, so it looks
/// exactly as an agent's render does), and an HTML tile as a self-contained page.
extension CanvasView {
    /// Pixels per canvas point for exported pictures: sharp on Retina screens and in documents.
    static let exportScale = 2.0

    /// The selection drawn offscreen (tiles, drawings, groups under it; no app chrome), as PNG,
    /// with the groups whose members are all selected (`SelectionScope.export`), so their titles
    /// and borders aren't cut.
    private func selectionPNG() async throws -> Data {
        guard !selection.isEmpty else { throw ExportFailure("nothing is selected") }
        let groups = board.objects.values.compactMap { object in
            object.type == .group ? GroupSpec(object.props).map { SelectionScope.Group(id: object.id, members: $0.members) } : nil
        }
        let ids = SelectionScope.export(selection: selection, groups: groups).sorted()
        return try await render(RenderRequest(target: .objects(ids), scale: Self.exportScale, padding: 0), format: .png).image
    }

    /// A file name for the selection: the one object's title, else "Canvas selection"
    /// (`ExportFile.name`).
    private func exportName(_ ext: String) -> String {
        var title = selection.count == 1 ? selection.first.flatMap { board.objects[$0] }.map(TileFrameView.title(for:)) : nil
        // An image tile's title is its file name: `chart.png` saves as `chart.png`, not `chart.png.png`.
        if let name = title, LocalImage.extensions.contains((name as NSString).pathExtension.lowercased()) || (name as NSString).pathExtension.lowercased() == "html" {
            title = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return ExportFile.name(title, ext: ext)
    }

    private static let exportDirectoryKey = "canvas.exportDirectory"

    /// A save sheet for an export: named for the selection, opening in the folder the user last
    /// saved one into, else Downloads, never the board's directory (`ExportFile.directory`).
    private func exportPanel(_ type: UTType, ext: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = exportName(ext)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let last = UserDefaults.standard.string(forKey: Self.exportDirectoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.directoryURL = ExportFile.directory(lastUsed: last, boardRoot: board.root, downloads: downloads) { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        return panel
    }

    /// Remembers where the user saved an export, for the next save sheet.
    private static func rememberExportDirectory(of url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: exportDirectoryKey)
    }

    /// Copy as Image: PNG (and TIFF, for apps that only read that) on the general pasteboard.
    func copySelectionAsImage() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let png = try await self.selectionPNG()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.declareTypes([.png, .tiff], owner: nil)
                pasteboard.setData(png, forType: .png)
                if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
                NSLog("Canvas: copied %d object(s) as a %d-byte PNG", self.selection.count, png.count)
            } catch {
                self.exportFailed("Copy as Image", error)
            }
        }
    }

    /// Save as PNG…: a save sheet on the window, then the same picture as Copy as Image.
    func saveSelectionAsPNG() {
        guard let window else { return }
        let panel = exportPanel(.png, ext: "png")
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Self.rememberExportDirectory(of: url)
            Task { @MainActor in
                do {
                    try await Self.write(try await self.selectionPNG(), to: url)
                    NSLog("Canvas: saved the selection as %@", url.path)
                } catch {
                    self.exportFailed("Save as PNG", error)
                }
            }
        }
    }

    /// Save as HTML…: the HTML tile's page as it renders, in one file (`HtmlTile.exportDocument`).
    func saveHTML(_ id: ObjectID) {
        guard let window, let tile = tiles[id]?.content as? HtmlTile else { return }
        let panel = exportPanel(.html, ext: "html")
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Self.rememberExportDirectory(of: url)
            Task { @MainActor in
                do {
                    try await Self.write(Data(try await tile.exportDocument().utf8), to: url)
                    NSLog("Canvas: saved HTML tile %@ as %@", id, url.path)
                } catch {
                    self.exportFailed("Save as HTML", error)
                }
            }
        }
    }

    /// Open in Browser: the exported page in the temp directory, opened by the default browser.
    /// A development instance that may not activate other apps (`CANVAS_NO_ACTIVATE`) only logs
    /// the file it would open.
    func openHTMLInBrowser(_ id: ObjectID) {
        guard let tile = tiles[id]?.content as? HtmlTile else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-exports", isDirectory: true)
        let url = directory.appendingPathComponent("\(id)-\(exportName("html"))")
        Task { @MainActor [weak self] in
            do {
                let html = try await tile.exportDocument()
                try await Self.write(Data(html.utf8), to: url)
                if CanvasApplication.neverActivate {
                    NSLog("Canvas: Open in Browser would open %@ (CANVAS_NO_ACTIVATE)", url.absoluteString)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                self?.exportFailed("Open in Browser", error)
            }
        }
    }

    private static func write(_ data: Data, to url: URL) async throws {
        try await offPool {
            Result { () throws -> Void in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }.get()
    }

    /// A sheet saying what failed; never app-modal.
    private func exportFailed(_ action: String, _ error: Error) {
        let message = (error as? ExportFailure)?.message ?? (error as? ApiRouter.Failure)?.message ?? error.localizedDescription
        NSLog("Canvas: %@ failed: %@", action, message)
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(action) failed"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

struct ExportFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension HtmlTile {
    /// The page as one self-contained file, as it renders now: loaded offscreen like a render
    /// (excerpts, Mermaid, and Tailwind settled), then its DOM with images inlined as `data:` URLs,
    /// the kit stylesheet inlined, and scripts dropped (the generated styles, `<canvas-code>` rows
    /// and diagrams are already in the DOM). It opens anywhere: a browser, an email attachment.
    func exportDocument() async throws -> String {
        let (html, reason) = await withOffscreenPage(size: RenderMath.body(of: object), appearance: effectiveAppearance) { web in
            try await web.callAsyncJavaScript(Self.exportScript, arguments: [:], in: nil, contentWorld: .page) as? String
        }
        guard let html = html ?? nil else { throw ExportFailure(reason ?? "the page produced no document") }
        return html
    }

    /// Runs as the body of an async function in the page.
    static let exportScript = """
    const dataURL = async (url) => {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`${response.status}`);
      const blob = await response.blob();
      return await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      });
    };
    const images = [...document.querySelectorAll('img')];
    const clone = document.documentElement.cloneNode(true);
    const copies = [...clone.querySelectorAll('img')];
    for (let i = 0; i < copies.length; i++) {
      const source = images[i] && (images[i].currentSrc || images[i].src);
      copies[i].removeAttribute('srcset');
      if (source && !source.startsWith('data:')) {
        try { copies[i].setAttribute('src', await dataURL(source)); } catch (error) {}
      }
    }
    for (const link of [...clone.querySelectorAll('link[rel="stylesheet"]')]) {
      try {
        const style = document.createElement('style');
        style.textContent = await (await fetch(link.href)).text();
        link.replaceWith(style);
      } catch (error) { link.remove(); }
    }
    for (const script of [...clone.querySelectorAll('script')]) script.remove();
    return '<!doctype html>\\n' + clone.outerHTML;
    """
}
