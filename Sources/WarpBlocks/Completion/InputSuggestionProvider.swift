import Foundation

final class InputSuggestionProvider {
    private let historyReader = AtuinHistoryReader()
    private let fileManager = FileManager.default

    func suggest(text: String, cwd: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let lastToken = lastToken(in: text) else { return nil }
        if looksLikePath(lastToken) {
            return pathCompletion(fullText: text, lastToken: lastToken, cwd: cwd)
        }
        return historyReader.suggestPrefix(trimmed)
    }

    private func lastToken(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        if end == text.startIndex { return nil }
        var start = end
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev].isWhitespace { break }
            start = prev
        }
        return String(text[start..<end])
    }

    private func looksLikePath(_ token: String) -> Bool {
        if token.hasPrefix("/") { return true }
        if token.hasPrefix("~/") || token == "~" { return true }
        if token.hasPrefix("./") || token.hasPrefix("../") { return true }
        if token.count > 1, token.dropFirst().contains("/") { return true }
        return false
    }

    private func pathCompletion(fullText: String, lastToken: String, cwd: String) -> String? {
        guard let (parentDir, namePrefix, prefixThroughSlash) = pathParts(lastToken, cwd: cwd) else {
            return nil
        }
        guard fileManager.fileExists(atPath: parentDir) else { return nil }
        guard let names = try? fileManager.contentsOfDirectory(atPath: parentDir) else { return nil }

        let matches = names.filter { name in
            if namePrefix.isEmpty { return true }
            return name.range(of: namePrefix, options: [.anchored, .caseInsensitive]) != nil
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        guard let match = matches.first else { return nil }

        let matchPath = (parentDir as NSString).appendingPathComponent(match)
        var isDir: ObjCBool = false
        fileManager.fileExists(atPath: matchPath, isDirectory: &isDir)
        let suffix = isDir.boolValue ? "/" : ""

        let newLastToken = prefixThroughSlash + match + suffix
        return replaceLastToken(in: fullText, with: newLastToken)
    }

    private func pathParts(_ lastToken: String, cwd: String) -> (parentDir: String, namePrefix: String, prefixThroughSlash: String)? {
        let token = lastToken
        if token.hasSuffix("/"), token.count > 1 {
            let withoutSlash = String(token.dropLast())
            let parentDir = expandingPath(withoutSlash, cwd: cwd)
            return (parentDir, "", token)
        }

        guard let slashIdx = token.lastIndex(of: "/") else {
            if token == "~" {
                let home = (token as NSString).expandingTildeInPath
                return (home, "", "~/")
            }
            return (cwd, token, "")
        }

        let dirPart = String(token[..<slashIdx])
        let namePart = String(token[token.index(after: slashIdx)...])
        let throughSlash = String(token[...slashIdx])

        let parentDir: String
        if dirPart.isEmpty {
            parentDir = "/"
        } else {
            parentDir = expandingPath(dirPart, cwd: cwd)
        }
        return (parentDir, namePart, throughSlash)
    }

    private func expandingPath(_ path: String, cwd: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return (path as NSString).expandingTildeInPath
        }
        if path.hasPrefix("/") {
            return path
        }
        return URL(fileURLWithPath: cwd).appendingPathComponent(path).standardizedFileURL.path
    }

    private func replaceLastToken(in fullText: String, with newLastToken: String) -> String? {
        guard !fullText.isEmpty else { return nil }
        var end = fullText.endIndex
        while end > fullText.startIndex, fullText[fullText.index(before: end)].isWhitespace {
            end = fullText.index(before: end)
        }
        if end == fullText.startIndex { return nil }
        var start = end
        while start > fullText.startIndex {
            let prev = fullText.index(before: start)
            if fullText[prev].isWhitespace { break }
            start = prev
        }
        let head = String(fullText[..<start])
        let tail = String(fullText[end...])
        if head.isEmpty {
            return newLastToken + tail
        }
        return head + newLastToken + tail
    }
}
