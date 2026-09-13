import Foundation
import SwiftData

/// A dated tasting impression. A wine can have many over time (you taste the
/// same bottle across years), each with an optional 100-point score.
@Model
final class TastingNote {
    var id: UUID
    var wine: Wine?
    var date: Date
    var score: Int?
    var text: String

    init(date: Date = .now, score: Int? = nil, text: String) {
        self.id = UUID()
        self.date = date
        self.score = score
        self.text = text
    }
}
