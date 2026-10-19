import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ExtractError: LocalizedError {
    case unsupported(String), empty, unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): "Can't read .\(ext) files."
        case .empty: "No readable text found in that file."
        case .unreadable(let why): "Couldn't read the file: \(why)"
        }
    }
}

/// Pulls readable text out of documents. Scanned PDF pages are OCR'd on-device with Vision.
enum Extractor {
    static let extensions = ["pdf", "epub", "docx", "doc", "odt", "rtf", "rtfd", "html", "htm", "txt", "text", "md", "markdown"]
    static var contentTypes: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }

    static func extract(_ url: URL, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let raw: String
        switch ext {
        case "pdf": raw = try await pdf(url, progress: progress)
        case "epub": raw = try epub(url)
        case "html", "htm": raw = htmlToText(try String(contentsOf: url, encoding: .utf8))
        case "docx", "doc", "odt", "rtf", "rtfd": raw = try attributed(url, ext)
        case "md", "markdown": raw = stripMarkdown(try readText(url))
        case "txt", "text": raw = try readText(url)
        default: throw ExtractError.unsupported(ext)
        }
        let text = clean(raw)
        if text.isEmpty { throw ExtractError.empty }
        return text
    }

    // MARK: - PDF

    private static func pdf(_ url: URL, progress: (String) -> Void) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.unreadable("not a valid PDF") }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var lines = (page.string ?? "").components(separatedBy: .newlines)
            if lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {  // probably a scan
                progress("Recognizing text on page \(i + 1) of \(doc.pageCount)…")
                lines = try await ocr(page)
            }
            pages.append(reflow(lines))
        }
        return pages.joined(separator: "\n\n")
    }

    private static func ocr(_ page: PDFPage) async throws -> [String] {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height)
        let img = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err { return cont.resume(throwing: err) }
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                cont.resume(returning: obs.compactMap { $0.topCandidates(1).first?.string })
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { cont.resume(throwing: error) }
        }
    }

    /// PDFs break lines mid-sentence; stitch them back into paragraphs.
    static func reflow(_ rawLines: [String]) -> String {
        let pageNumber = try! Regex(#"(?i)^(page\s*)?\d{1,4}$"#)
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { (try? pageNumber.wholeMatch(in: $0)) == nil }
        let lengths = lines.filter { !$0.isEmpty }.map(\.count).sorted()
        let full = lengths.isEmpty ? 80 : lengths[Int(Double(lengths.count) * 0.75)]
        var out: [String] = [], prevRaw = ""
        for ln in lines {
            if ln.isEmpty {
                if let last = out.last, !last.isEmpty { out.append("") }
                continue
            }
            if let joined = out.last, !joined.isEmpty {
                let short = Double(prevRaw.count) < Double(full) * 0.8  // ended early: paragraph end or heading
                let startsLower = ln.first?.isLowercase ?? false
                if joined.hasSuffix("-") && startsLower {
                    out[out.count - 1] = String(joined.dropLast()) + ln; prevRaw = ln; continue
                }
                if startsLower || !short {
                    out[out.count - 1] = joined + " " + ln; prevRaw = ln; continue
                }
            }
            out.append(ln); prevRaw = ln
        }
        return out.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Other formats

    private static func readText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &enc)
    }

    private static func attributed(_ url: URL, _ ext: String) throws -> String {
        let type: NSAttributedString.DocumentType = switch ext {
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "odt": .openDocument
        case "rtfd": .rtfd
        default: .rtf
        }
        do {
            // Word/RTF paragraphs end with a single newline; make them blank-line separated like everything else.
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
                .replacingOccurrences(of: "\n", with: "\n\n")
        } catch {
            throw ExtractError.unreadable(error.localizedDescription)
        }
    }

    private static func epub(_ url: URL) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "audiomaker-epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "-d", tmp.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw ExtractError.unreadable("not a valid EPUB") }

        func attr(_ name: String, in tag: String) -> String? {
            guard let m = tag.firstMatch(of: try! Regex("\(name)\\s*=\\s*[\"']([^\"']+)[\"']")) else { return nil }
            return m.output[1].substring.map(String.init)
        }
        let container = try String(contentsOf: tmp.appending(path: "META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = attr("full-path", in: container) else { throw ExtractError.unreadable("missing EPUB manifest") }
        let opfURL = tmp.appending(path: opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var manifest: [String: String] = [:]
        for m in opf.matches(of: try! Regex(#"<item\b[^>]*>"#)) {
            let tag = String(m.output[0].substring ?? "")
            if let id = attr("id", in: tag), let href = attr("href", in: tag) { manifest[id] = href }
        }
        let base = opfURL.deletingLastPathComponent()
        var parts: [String] = []
        for m in opf.matches(of: try! Regex(#"<itemref\b[^>]*>"#)) {
            let tag = String(m.output[0].substring ?? "")
            guard let idref = attr("idref", in: tag), let href = manifest[idref],
                  let html = try? String(contentsOf: base.appending(path: href.removingPercentEncoding ?? href), encoding: .utf8)
            else { continue }
            parts.append(htmlToText(html))
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    /// Lightweight HTML → text: block elements become paragraph breaks, tags dropped, entities decoded.
    static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacing(try! Regex(#"(?is)<(script|style|head|nav)\b.*?</\1>"#), with: "")
        s = s.replacing(try! Regex(#"(?i)<br\s*/?>"#), with: "\n")
        s = s.replacing(try! Regex(#"(?i)</?(p|div|h[1-6]|li|blockquote|section|article|tr|pre)\b[^>]*>"#), with: "\n\n")
        s = s.replacing(try! Regex(#"<[^>]+>"#), with: "")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
                        "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
                        "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacing(try! Regex(#"&#(x?)([0-9a-fA-F]+);"#)) { m in
            let hex = m.output[1].substring == "x"
            guard let digits = m.output[2].substring, let code = UInt32(digits, radix: hex ? 16 : 10),
                  let scalar = Unicode.Scalar(code) else { return "" }
            return String(Character(scalar))
        }
        // Collapse whitespace inside paragraphs.
        return s.split(separator: try! Regex(#"\n\s*\n"#))
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func stripMarkdown(_ text: String) -> String {
        var s = text
        s = s.replacing(try! Regex(#"(?s)```.*?```"#), with: "")
        s = s.replacing(try! Regex(#"!\[[^\]]*\]\([^)]*\)"#), with: "")
        s = s.replacing(try! Regex(#"\[([^\]]*)\]\([^)]*\)"#)) { String($0.output[1].substring ?? "") }
        s = s.replacing(try! Regex(#"(?m)^#{1,6}\s*"#), with: "")
        s = s.replacing(try! Regex(#"[*_`]{1,3}"#), with: "")
        return s
    }

    static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{0}", with: "")
        s = s.replacing(try! Regex(#"[ \t]+"#), with: " ")
        s = s.replacing(try! Regex(#"\n{3,}"#), with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
