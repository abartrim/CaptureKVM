import Foundation
import AppKit

enum KeycodeMap {
    // macOS virtual keyCode -> HID usage (US layout, HID Usage Page 0x07)
    private static let table: [UInt16: UInt8] = [
        // Letters A-Z
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09,
        5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D, 40: 0x0E, 37: 0x0F,
        46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15,
        1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B,
        16: 0x1C, 6: 0x1D,
        // Top-row digits 1-9, 0
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22,
        22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
        // Punctuation
        27: 0x2D, // - _
        24: 0x2E, // = +
        33: 0x2F, // [ {
        30: 0x30, // ] }
        42: 0x31, // \ |
        41: 0x33, // ; :
        39: 0x34, // ' "
        50: 0x35, // ` ~
        43: 0x36, // , <
        47: 0x37, // . >
        44: 0x38, // / ?
        // Whitespace / editing
        36: 0x28, // Return
        48: 0x2B, // Tab
        49: 0x2C, // Space
        51: 0x2A, // Backspace
        53: 0x29, // Escape
        57: 0x39, // Caps Lock
        // Function keys F1-F12
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F,
        98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
        // Function keys F13-F20 (extended keyboards)
        105: 0x68, 107: 0x69, 113: 0x6A, 106: 0x6B,
        64:  0x6C, 79:  0x6D, 80:  0x6E, 90:  0x6F,
        // Navigation cluster
        114: 0x49, // Help (mapped to Insert)
        115: 0x4A, // Home
        116: 0x4B, // Page Up
        117: 0x4C, // Forward Delete
        119: 0x4D, // End
        121: 0x4E, // Page Down
        // Arrows
        123: 0x50, // Left
        124: 0x4F, // Right
        125: 0x51, // Down
        126: 0x52, // Up
        // Numpad
        82: 0x62, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C, 87: 0x5D,
        88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61,
        65: 0x63, // Numpad .
        67: 0x55, // Numpad *
        69: 0x57, // Numpad +
        71: 0x53, // Num Lock / Clear
        75: 0x54, // Numpad /
        76: 0x58, // Numpad Enter
        78: 0x56, // Numpad -
        81: 0x67, // Numpad =
    ]

    // Returns (usage, modifierBit) where modifierBit is HID modifier mask to toggle.
    // In practice, modifier presses arrive via flagsChanged (handled separately);
    // the modifier branch here is a harmless fallback.
    static func usUsage(for event: NSEvent) -> (UInt8?, UInt8?) {
        let kc = event.keyCode
        switch kc {
        case 56, 60: return (nil, 0x02) // Shift (L/R)
        case 59, 62: return (nil, 0x01) // Control (L/R)
        case 58, 61: return (nil, 0x04) // Option (L/R)
        case 55, 54: return (nil, 0x08) // Command (L/R)
        default: break
        }
        return (table[kc], nil)
    }
}

// MARK: - Clipboard paste support

/// Maps a printable character to the HID usage required to type it on a US keyboard,
/// plus whether the Shift modifier is needed. Used by paste-from-host.
enum USCharacterMap {
    static func usage(for ch: Character) -> (usage: UInt8, shift: Bool)? {
        return table[ch]
    }

    private static let table: [Character: (UInt8, Bool)] = {
        var m: [Character: (UInt8, Bool)] = [:]
        // a-z / A-Z
        for (i, c) in Array("abcdefghijklmnopqrstuvwxyz").enumerated() {
            let u = UInt8(0x04 + i)
            m[c] = (u, false)
            m[Character(String(c).uppercased())] = (u, true)
        }
        // Top-row digits and their shifted symbols
        let digits: [(Character, UInt8, Character)] = [
            ("1", 0x1E, "!"), ("2", 0x1F, "@"), ("3", 0x20, "#"),
            ("4", 0x21, "$"), ("5", 0x22, "%"), ("6", 0x23, "^"),
            ("7", 0x24, "&"), ("8", 0x25, "*"), ("9", 0x26, "("),
            ("0", 0x27, ")"),
        ]
        for (d, u, s) in digits { m[d] = (u, false); m[s] = (u, true) }
        // Punctuation: unshifted / shifted
        let punct: [(Character, UInt8, Character)] = [
            ("-", 0x2D, "_"),
            ("=", 0x2E, "+"),
            ("[", 0x2F, "{"),
            ("]", 0x30, "}"),
            ("\\", 0x31, "|"),
            (";", 0x33, ":"),
            ("'", 0x34, "\""),
            ("`", 0x35, "~"),
            (",", 0x36, "<"),
            (".", 0x37, ">"),
            ("/", 0x38, "?"),
        ]
        for (b, u, s) in punct { m[b] = (u, false); m[s] = (u, true) }
        // Whitespace
        m[" "] = (0x2C, false)
        m["\n"] = (0x28, false)  // LF -> Return
        m["\t"] = (0x2B, false)
        return m
    }()
}

enum HIDEncoder {
    static func crc8(data: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x00
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    static func cobsEncode(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count + 2)
        var codeIndex = 0
        var code: UInt8 = 1
        out.append(0) // placeholder
        for byte in input {
            if byte == 0 {
                out[codeIndex] = code
                codeIndex = out.count
                out.append(0) // placeholder for next code
                code = 1
            } else {
                out.append(byte)
                code &+= 1
                if code == 0xFF {
                    out[codeIndex] = code
                    codeIndex = out.count
                    out.append(0)
                    code = 1
                }
            }
        }
        out[codeIndex] = code
        return out
    }

    static func frame(type: UInt8, payload: [UInt8]) -> Data {
        var buf: [UInt8] = [type]
        buf.append(contentsOf: payload)
        let crc = crc8(data: buf)
        buf.append(crc)
        var encoded = cobsEncode(buf)
        encoded.append(0x00) // delimiter
        return Data(encoded)
    }
}
