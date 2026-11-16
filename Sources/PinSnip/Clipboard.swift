import AppKit
import UniformTypeIdentifiers

/// What the clipboard currently holds, in the priority order the request asks
/// for: image, then text, then an image file.
struct ClipboardContent {
    enum Kind {
        case image(NSImage)
        case text(String)
    }

    var kind: Kind
    /// Stable identity of the content, so pressing the paste hotkey twice in a
    /// row does not create two identical pins.
    var stamp: String

    static func read() -> ClipboardContent? {
        let pasteboard = NSPasteboard.general

        // Password managers tag copied secrets as concealed. Never pin those.
        if isConcealed(pasteboard) { return nil }

        if let image = readImage(pasteboard) {
            return ClipboardContent(kind: .image(image), stamp: "img:" + imageStamp(image))
        }

        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipboardContent(kind: .text(text), stamp: "text:" + String(text.hashValue))
        }

        if let url = readFileURL(pasteboard), let image = NSImage(contentsOf: url) {
            return ClipboardContent(kind: .image(image), stamp: "file:" + imageStamp(image) + ":" + url.absoluteString)
        }

        return nil
    }

    /// True when the clipboard entry is marked as concealed, the flag password
    /// managers set so other apps do not read the secret back.
    private static func isConcealed(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { type in
            type.rawValue.localizedCaseInsensitiveContains("concealedtype")
        }
    }

    private static func readImage(_ pasteboard: NSPasteboard) -> NSImage? {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in types {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        if let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: [:]),
           let image = objects.first as? NSImage {
            return image
        }
        return nil
    }

    private static func readFileURL(_ pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options),
              let url = objects.first as? URL else {
            return nil
        }
        return url
    }

    /// Cheap content fingerprint: enough to recognise the same clipboard entry.
    private static func imageStamp(_ image: NSImage) -> String {
        guard let tiff = image.tiffRepresentation else {
            return "\(Int(image.size.width))x\(Int(image.size.height))"
        }
        var hash = tiff.count
        let stride = max(1, tiff.count / 64)
        var index = tiff.startIndex
        while index < tiff.endIndex {
            hash = hash &* 31 &+ Int(tiff[index])
            index = tiff.index(index, offsetBy: stride)
        }
        return "\(hash):\(Int(image.size.width))x\(Int(image.size.height))"
    }
}
