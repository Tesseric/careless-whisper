import AppKit
import os

enum ClipboardImageError: LocalizedError {
    case noImageOnClipboard
    case failedToReadImage
    case failedToConvertPNG
    case failedToCreateDirectory(Error)
    case failedToWriteFile(Error)

    var errorDescription: String? {
        switch self {
        case .noImageOnClipboard:
            return "No image found on the clipboard."
        case .failedToReadImage:
            return "Failed to read image from the clipboard."
        case .failedToConvertPNG:
            return "Failed to convert clipboard image to PNG."
        case .failedToCreateDirectory(let error):
            return "Failed to create image directory: \(error.localizedDescription)"
        case .failedToWriteFile(let error):
            return "Failed to write image file: \(error.localizedDescription)"
        }
    }
}

final class ClipboardImageService {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "ClipboardImage")

    private static let imageDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".careless-whisper/images")
    }()

    /// Checks the system clipboard for an image.
    /// Returns whether an image is present and the pasteboard's change count for staleness detection.
    func detectClipboardImage() -> (hasImage: Bool, changeCount: Int) {
        let pasteboard = NSPasteboard.general
        let hasImage = pasteboard.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
        ])
        return (hasImage, pasteboard.changeCount)
    }

    /// Reads the clipboard image, converts it to PNG, and saves it to disk.
    /// Returns the absolute path of the saved file.
    func saveClipboardImage() throws -> String {
        let pasteboard = NSPasteboard.general

        guard let image = NSImage(pasteboard: pasteboard) else {
            logger.warning("No image could be read from pasteboard")
            throw ClipboardImageError.failedToReadImage
        }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.warning("Failed to convert clipboard image to PNG")
            throw ClipboardImageError.failedToConvertPNG
        }

        // Ensure directory exists
        let directory = Self.imageDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create image directory: \(error)")
            throw ClipboardImageError.failedToCreateDirectory(error)
        }

        // Generate timestamped filename (fractional seconds to avoid collisions)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: Date())
        let fileName = "clipboard-\(timestamp).png"
        let filePath = directory.appendingPathComponent(fileName)

        do {
            try pngData.write(to: filePath)
        } catch {
            logger.error("Failed to write image file: \(error)")
            throw ClipboardImageError.failedToWriteFile(error)
        }

        let path = filePath.path
        logger.info("Saved clipboard image: \(path)")

        pruneOldImages()

        return path
    }

    /// Deletes images older than 24 hours from the image directory.
    private func pruneOldImages() {
        let directory = Self.imageDirectory
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }

        for file in files {
            guard file.pathExtension == "png" else { continue }
            guard let values = try? file.resourceValues(forKeys: [.creationDateKey]),
                  let created = values.creationDate,
                  created < cutoff else { continue }
            try? fm.removeItem(at: file)
            logger.info("Pruned old image: \(file.lastPathComponent)")
        }
    }
}
