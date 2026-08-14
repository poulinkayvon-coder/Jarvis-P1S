import Foundation

enum PrinterState: String, Codable {
    case offline, idle, preparing, printing, paused, finished, error
}

struct PrinterStatus: Codable, Equatable {
    var state: PrinterState = .offline
    var progress: Double = 0
    var remainingSeconds: Int?
    var bedTemperature: Double?
    var nozzleTemperature: Double?
    var jobName: String?
    var errorMessage: String?
}

struct AMSFilament: Identifiable, Codable, Equatable {
    let id: String
    var slot: Int
    var material: String
    var colorName: String
    var hexColor: String?
    var isLoaded: Bool
}

struct AMSState: Codable, Equatable {
    var filaments: [AMSFilament] = []
}

struct ModelCandidate: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let downloadURL: URL
    let source: String
    let notes: String?
    let printer: String
}

struct PrintFilament: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var material: String
    var requestedColorName: String?
}

struct FilamentMapping: Identifiable, Codable, Equatable {
    let id: String
    let printFilamentID: String
    let amsSlot: Int
    let confidence: Double
}

enum JarvisCommand: Equatable {
    case status
    case findAndPrint(query: String, requestedColor: String?, requestedSlot: Int?)
    case confirmPrint
    case declinePrint
    case pause
    case resume
    case cancel
    case unknown
}
