import Foundation

struct AMSMapper {
    func suggestMappings(
        printFilaments: [PrintFilament],
        ams: AMSState,
        requestedSlot: Int? = nil
    ) -> [FilamentMapping] {
        printFilaments.compactMap { requested in
            let candidates = ams.filaments.filter {
                $0.isLoaded &&
                $0.material.caseInsensitiveCompare(requested.material) == .orderedSame &&
                (requestedSlot == nil || $0.slot == requestedSlot)
            }

            guard let best = candidates.max(by: {
                score($0, requested) < score($1, requested)
            }) else { return nil }

            return FilamentMapping(
                id: UUID().uuidString,
                printFilamentID: requested.id,
                amsSlot: best.slot,
                confidence: score(best, requested)
            )
        }
    }

    private func score(_ actual: AMSFilament, _ requested: PrintFilament) -> Double {
        guard let wanted = requested.requestedColorName?.lowercased() else { return 0.5 }
        let actualName = actual.colorName.lowercased()
        if actualName == wanted { return 1.0 }
        if actualName.contains(wanted) || wanted.contains(actualName) { return 0.9 }
        return 0.5
    }
}
