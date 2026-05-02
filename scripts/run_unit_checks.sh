#!/usr/bin/env bash
set -euo pipefail

swift - <<'SWIFT'
import Foundation

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>")
    let decoded = value.removingPercentEncoding ?? value
    let cleaned = decoded.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.nilIfEmpty ?? "video"
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

check(sanitizedFileName("bad/name%3F.mp4") == "bad-name-.mp4", "invalid filename characters are sanitized")
check(sanitizedFileName("   ") == "video", "blank filename falls back to video")
check(sanitizedFileName("video.mp4") == "video.mp4", "safe filename is preserved")

print("Unit checks passed")
SWIFT
