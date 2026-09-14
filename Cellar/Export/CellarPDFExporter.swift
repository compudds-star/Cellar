import Foundation
import UIKit

/// Renders a one-or-more page PDF summary of the cellar: totals up top, then a
/// line per wine (vintage/name, in-stock count, rating, estimated value).
enum CellarPDFExporter {

    static func write(_ wines: [Wine]) throws -> URL {
        let stats = CellarStats(wines: wines)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, 72dpi
        let margin: CGFloat = 48
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cellar-\(CellarCSVExporter.fileStamp()).pdf")

        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 22)]
        let subAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.darkGray]
        let rowAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12)]
        let rightRow: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.darkGray]

        let sorted = wines
            .filter { !$0.inStockBottles.isEmpty }
            .sorted { $0.totalEstimatedValue > $1.totalEstimatedValue }

        try renderer.writePDF(to: url) { ctx in
            var y: CGFloat = margin
            ctx.beginPage()

            "Cellar".draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttr)
            y += 30
            let df = DateFormatter(); df.dateStyle = .long
            """
            \(stats.bottleCount) bottles · \(stats.wineCount) wines · Estimated value \(Money.string(stats.totalValue))\(stats.pricedBottleCount > 0 ? " · Paid \(Money.string(stats.paidTotal))" : "")\(stats.gainDescription.map { " · Gain \($0)" } ?? "")
            Exported \(df.string(from: .now))
            """.draw(in: CGRect(x: margin, y: y, width: pageRect.width - 2*margin, height: 34),
                     withAttributes: subAttr)
            y += 44
            if stats.hasUnvaluedBottles {
                "Note: \(stats.bottleCount - stats.valuedBottleCount) bottle(s) have no estimate — total is a floor."
                    .draw(at: CGPoint(x: margin, y: y), withAttributes: subAttr)
                y += 20
            }
            y += 8

            // A total per collection, when bottles are grouped into collections.
            let collections = Dictionary(grouping: wines.flatMap(\.inStockBottles).compactMap(\.collection), by: \.id)
                .compactMap { $0.value.first }
                .sorted { $0.name < $1.name }
            if !collections.isEmpty {
                var scopes = collections.map { CollectionScope.collection($0) }
                if CellarStats(wines: wines, scope: .unassigned).bottleCount > 0 { scopes.append(.unassigned) }
                for scope in scopes {
                    let s = CellarStats(wines: wines, scope: scope)
                    "\(scope.title): \(s.bottleCount) bottle(s) · \(Money.string(s.totalValue))"
                        .draw(at: CGPoint(x: margin, y: y), withAttributes: subAttr)
                    y += 16
                }
                y += 8
            }

            for wine in sorted {
                if y > pageRect.height - margin {
                    ctx.beginPage()
                    y = margin
                }
                let left = "\(wine.displayTitle)  ×\(wine.inStockCount)"
                left.draw(at: CGPoint(x: margin, y: y), withAttributes: rowAttr)

                var right = Money.string(wine.totalEstimatedValue)
                if let r = wine.rating, r > 0 { right = "\(r)★ · " + right }
                else if let s = wine.communityScore { right = "\(s)pt · " + right }
                let rightSize = (right as NSString).size(withAttributes: rightRow)
                right.draw(at: CGPoint(x: pageRect.width - margin - rightSize.width, y: y),
                           withAttributes: rightRow)
                y += 20
            }
        }
        return url
    }
}
