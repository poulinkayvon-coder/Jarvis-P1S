import Foundation

struct CommandParser {
    func parse(_ input: String) -> JarvisCommand {
        let s = input.lowercased()
            .replacingOccurrences(of: "hey jarvis", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if s.contains("status") || (s.contains("what") && s.contains("printer")) {
            return .status
        }
        if s.contains("pause") { return .pause }
        if s.contains("resume") || s.contains("continue") { return .resume }
        if s.contains("cancel") || s.contains("stop the print") { return .cancel }

        guard s.contains("print") || s.contains("make") || s.contains("start") else {
            return .unknown
        }

        var object = s
        for prefix in ["print me", "print a", "print an", "print", "make me", "make a", "make an", "make", "start"] {
            if object.hasPrefix(prefix) {
                object.removeFirst(prefix.count)
                break
            }
        }
        object = object.trimmingCharacters(in: .whitespacesAndNewlines)

        var slot: Int?
        if let range = object.range(of: #"slot\s*([1-4])"#, options: .regularExpression),
           let number = Int(object[range].filter(\.isNumber)) {
            slot = number
            object.removeSubrange(range)
        }

        var color: String?
        let colors = ["red", "blue", "green", "yellow", "orange", "purple", "white", "black", "gray", "grey"]
        for c in colors where object.contains(c) {
            color = c
            object = object.replacingOccurrences(of: c, with: "")
            break
        }

        object = object
            .replacingOccurrences(of: "using ams", with: "")
            .replacingOccurrences(of: "in the ams", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return object.isEmpty ? .unknown : .findAndPrint(query: object, requestedColor: color, requestedSlot: slot)
    }
}
