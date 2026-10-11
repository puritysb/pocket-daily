#!/usr/bin/env swift
// Local, offline semantic checks over the physical reader's exported PNGs.
// Pixel differences alone cannot distinguish a useful page from an empty one.
import Foundation
import Vision

struct ScreenCheckError: Error, CustomStringConvertible {
    let description: String
}
struct RecognizedLine {
    let text: String
    let y: Double // normalized, from top of the portrait page
    var normalized: String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
func read(_ directory: URL, _ name: String) throws -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "ko-KR"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(url: directory.appendingPathComponent(name + ".png")).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        return RecognizedLine(text: text, y: 1 - Double(observation.boundingBox.midY))
    }
}
func wordY(_ rows: [RecognizedLine]) throws -> Double {
    guard let row = rows.first(where: { $0.normalized.contains("dailyword") || $0.normalized.contains("오늘의단어") }) else {
        throw ScreenCheckError(description: "Daily Word label is missing or unreadable")
    }
    return row.y
}
func forecastY(_ rows: [RecognizedLine]) throws -> Double {
    let weekdays: Set<String> = ["sun", "mon", "tue", "wed", "thu", "fri", "sat", "일", "월", "화", "수", "목", "금", "토"]
    let positions = rows.flatMap { row in
        row.text.lowercased().split(whereSeparator: { !$0.isLetter })
            .filter { weekdays.contains(String($0)) }.map { _ in row.y }
    }
    guard positions.count >= 2 else { throw ScreenCheckError(description: "Forecast weekday row is missing or unreadable") }
    return positions.reduce(0, +) / Double(positions.count)
}
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
var results: [String: Bool] = [:]
var failure: String?
do {
    guard CommandLine.arguments.count == 2 else { throw ScreenCheckError(description: "Usage: verify_reader_screens.swift CAPTURE_DIRECTORY") }
    _ = try wordY(read(directory, "02-home-word"))
    results["home-word-label"] = true
    let bottom = try read(directory, "04-home-weather-bottom")
    let top = try read(directory, "05-home-weather-top")
    guard try forecastY(bottom) > wordY(bottom) + 0.1,
          try forecastY(top) + 0.1 < wordY(top) else {
        throw ScreenCheckError(description: "Weather is not on the requested side of the Home card")
    }
    results["weather-position"] = true
    let today = try read(directory, "07-brief-today").filter { $0.y > 0.12 && $0.y < 0.9 }
    let explained = today.contains { row in
        row.normalized.contains("nosavedevents") || row.normalized.contains("저장된일정이없습니다")
            || row.text.range(of: #"(?:[01]?\d|2[0-3]):[0-5]\d"#, options: .regularExpression) != nil
    }
    guard explained else { throw ScreenCheckError(description: "Today-only Brief has neither readable event times nor an empty-state explanation") }
    results["brief-today-content"] = true
    for name in ["09-card-image-a", "10-card-image-b", "11-card-image-restored"] {
        let text = try read(directory, name).map(\.normalized).joined()
        guard text.contains("imageverification") && text.contains("samewords") && text.contains("differentpicture") else {
            throw ScreenCheckError(description: "Card image case is missing its unchanged text: " + name)
        }
    }
    results["card-text-preserved"] = true
    let book = try read(directory, "12-reader-body").map(\.normalized).joined()
    guard book.contains("theamberfoxreadsbesidethequietriver"),
          book.contains("abluelanternmarksthesecondparagraph"),
          book.contains("thispagecomesfromthebookstoredonthereader") else {
        throw ScreenCheckError(description: "Actual EPUB page is missing the fixture paragraphs")
    }
    results["reader-body"] = true
    let sleep = try read(directory, "13-actual-sleep").filter { $0.y > 0.12 && $0.y < 0.9 }
    guard sleep.contains(where: { $0.normalized.contains("nosavedevents") || $0.normalized.contains("저장된일정이없습니다") ||
        $0.text.range(of: #"(?:[01]?\d|2[0-3]):[0-5]\d"#, options: .regularExpression) != nil }) else {
        throw ScreenCheckError(description: "Actual sleep frame is missing the selected Today content")
    }
    results["actual-sleep-frame"] = true
} catch { failure = String(describing: error) }
var report: [String: Any] = ["passed": failure == nil, "checks": results,
    "scope": "Offline OCR anchors on X3 Home, Brief, cards, EPUB body and actual sleep frame; not optical panel validation"]
if let failure { report["error"] = failure }
let output = directory.appendingPathComponent("semantic-validation.json")
do {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Cannot save semantic validation report\n".utf8))
    exit(1)
}
if let failure {
    FileHandle.standardError.write(Data((failure + "\n").utf8))
    exit(1)
}
print("Reader screen semantics passed: Home, Brief, cards, EPUB and sleep frame.")
