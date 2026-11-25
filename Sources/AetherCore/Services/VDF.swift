import Foundation

/// One node of Valve's KeyValues text format (`libraryfolders.vdf`, `appmanifest_*.acf`).
public struct VDFNode: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case children([VDFNode])
    }

    public var key: String
    public var value: Value

    public init(key: String, value: Value) {
        self.key = key
        self.value = value
    }

    public var stringValue: String? {
        if case .string(let s) = value { return s }
        return nil
    }

    public var children: [VDFNode] {
        if case .children(let c) = value { return c }
        return []
    }

    /// First child whose key matches. Valve keys are case-insensitive ("AppState" == "appstate").
    public subscript(key: String) -> VDFNode? {
        children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}

public enum VDFError: Error, Equatable {
    case unexpectedEndOfInput
    case unexpectedToken(String, offset: Int)
    case unterminatedString(offset: Int)
}

/// A small, strict KeyValues parser: quoted and bare tokens, `{ }` blocks, `//` comments,
/// `\\ \" \n \t` escapes. `[$PLATFORM]` conditionals and `#include` lines are skipped.
public enum VDFParser {
    /// Parses a whole document into a synthetic root node (empty key) holding the top-level entries.
    public static func parse(_ text: String) throws -> VDFNode {
        var lexer = Lexer(bytes: Array(text.utf8))
        return VDFNode(key: "", value: .children(try parseEntries(&lexer, nested: false)))
    }

    private static func parseEntries(_ lexer: inout Lexer, nested: Bool) throws -> [VDFNode] {
        var nodes: [VDFNode] = []
        while true {
            guard let token = try lexer.next() else {
                if nested { throw VDFError.unexpectedEndOfInput }
                return nodes
            }
            switch token {
            case .closeBrace:
                guard nested else { throw VDFError.unexpectedToken("}", offset: lexer.offset) }
                return nodes
            case .openBrace:
                throw VDFError.unexpectedToken("{", offset: lexer.offset)
            case .string(let key):
                guard let valueToken = try lexer.next() else { throw VDFError.unexpectedEndOfInput }
                switch valueToken {
                case .openBrace:
                    nodes.append(VDFNode(key: key, value: .children(try parseEntries(&lexer, nested: true))))
                case .string(let value):
                    nodes.append(VDFNode(key: key, value: .string(value)))
                case .closeBrace:
                    throw VDFError.unexpectedToken("}", offset: lexer.offset)
                }
            }
        }
    }

    private struct Lexer {
        enum Token: Equatable {
            case string(String)
            case openBrace
            case closeBrace
        }

        let bytes: [UInt8]
        var offset = 0

        private static let quote = UInt8(ascii: "\"")
        private static let backslash = UInt8(ascii: "\\")
        private static let newline = UInt8(ascii: "\n")

        mutating func next() throws -> Token? {
            skipTrivia()
            guard offset < bytes.count else { return nil }
            switch bytes[offset] {
            case UInt8(ascii: "{"):
                offset += 1
                return .openBrace
            case UInt8(ascii: "}"):
                offset += 1
                return .closeBrace
            case Self.quote:
                return .string(try quotedString())
            default:
                return .string(bareString())
            }
        }

        private mutating func skipTrivia() {
            while offset < bytes.count {
                let byte = bytes[offset]
                switch byte {
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), Self.newline:
                    offset += 1
                case UInt8(ascii: "/") where offset + 1 < bytes.count && bytes[offset + 1] == UInt8(ascii: "/"),
                     UInt8(ascii: "#"):
                    skip(through: Self.newline)
                case UInt8(ascii: "["):
                    skip(through: UInt8(ascii: "]"))
                default:
                    return
                }
            }
        }

        private mutating func skip(through terminator: UInt8) {
            while offset < bytes.count {
                defer { offset += 1 }
                if bytes[offset] == terminator { return }
            }
        }

        private mutating func quotedString() throws -> String {
            let start = offset
            offset += 1 // opening quote
            var out: [UInt8] = []
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == Self.quote {
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == Self.backslash, offset < bytes.count {
                    let escaped = bytes[offset]
                    offset += 1
                    switch escaped {
                    case UInt8(ascii: "n"): out.append(Self.newline)
                    case UInt8(ascii: "t"): out.append(UInt8(ascii: "\t"))
                    case Self.backslash, Self.quote: out.append(escaped)
                    default: out.append(contentsOf: [byte, escaped])
                    }
                } else {
                    out.append(byte)
                }
            }
            throw VDFError.unterminatedString(offset: start)
        }

        private mutating func bareString() -> String {
            let start = offset
            while offset < bytes.count {
                switch bytes[offset] {
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), Self.newline,
                     Self.quote, UInt8(ascii: "{"), UInt8(ascii: "}"):
                    return String(decoding: bytes[start..<offset], as: UTF8.self)
                default:
                    offset += 1
                }
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
    }
}
