import Foundation

enum ReviewCopy {
    enum Note: Equatable {
        case alreadyReviewed, alreadyDone, listUpdated, itemRemoved

        var text: String {
            switch self {
            case .alreadyReviewed: "Already reviewed on the web"
            case .alreadyDone: "Already done"
            case .listUpdated: "This list was updated"
            case .itemRemoved: "That item was removed"
            }
        }
    }

    static let transcribing = "Transcribing"
    static let finding = "Finding action items"
    static let slow = "Taking longer than usual. We'll let you know when it's ready."
    static let none = "No action items this time."
    static let nobody = "We didn't hear anyone speak in this recording."
    static let transcriptionFailed = "We couldn't transcribe this meeting."
    static let findingFailed = "We couldn't find action items this time."
    static let readOnly = "The series owner reviews these."
    static let skipRest = "Skip the rest"
    static let openRecap = "Open recap"
    static let tryAgain = "Try again"
    static let lessSure = "Less sure"
    static let groupNew = "New items"
    static let groupUpdates = "Updates to existing items"
    static let saving = "Saving"
    static let couldntSave = "Couldn't save. Try again."
    static let signedOut = "You were signed out. Sign in again to record."

    static func keep(_ n: Int) -> String { "Keep \(n)" }
    static func moreOnWeb(_ n: Int) -> String { "\(n) more on the web" }

    static func tracked(_ n: Int) -> String { "\(n == 0 ? "No" : "\(n)") \(n == 1 ? "item" : "items") tracked" }

    static func done(kept: Int, updated: Int) -> String {
        var parts: [String] = []
        if kept > 0 || updated == 0 { parts.append(tracked(kept)) }
        if updated > 0 { parts.append("\(updated) updated") }
        return parts.joined(separator: ", ")
    }

    static func partly(kept: Int, left: Int) -> String { "\(tracked(kept)). \(left) still to review." }

    static func notificationTitle(count: Int, series: String) -> String {
        "\(count) action \(count == 1 ? "item" : "items") from \(series)"
    }
}
