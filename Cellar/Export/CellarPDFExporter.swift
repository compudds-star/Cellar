import Foundation
import UIKit

/// One location's block in the PDF report: its wines (highest value first) and totals.
struct CellarReportSection {
    struct Line {
        let wine: Wine
        let count: Int
        let total: Decimal
        /// Estimated value per bottle here (average across sizes).
        let perBottle: Decimal
        /// Average price paid per bottle here, over the bottles with a price recorded.
        let paidPerBottle: Decimal?
    }

    let scope: CollectionScope
    let lines: [Line]
    var bottleCount: Int { lines.reduce(0) { $0 + $1.count } }
    var total: Decimal { lines.reduce(Decimal(0)) { $0 + $1.total } }

    /// Sections per collection (plus unassigned bottles), highest total first.
    /// With no collections at all there is a single `.all` section.
    static func sections(for wines: [Wine]) -> [CellarReportSection] {
        let inStock = wines.flatMap(\.inStockBottles)
        let collections = Dictionary(grouping: inStock.compactMap(\.collection), by: \.id)
            .compactMap { $0.value.first }
        var scopes: [CollectionScope] = collections.map { .collection($0) }
        if scopes.isEmpty {
            scopes = [.all]
        } else if inStock.contains(where: { $0.collection == nil }) {
            scopes.append(.unassigned)
        }
        return scopes
            .map { section(for: wines, scope: $0) }
            .filter { !$0.lines.isEmpty }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.scope.title < $1.scope.title }
    }

    static func section(for wines: [Wine], scope: CollectionScope) -> CellarReportSection {
        let lines = wines.compactMap { wine -> Line? in
            let bottles = wine.inStockBottles(in: scope)
            guard !bottles.isEmpty else { return nil }
            let total = wine.totalEstimatedValue(in: scope)
            let paid = bottles.compactMap(\.purchasePrice)
            return Line(wine: wine,
                        count: bottles.count,
                        total: total,
                        perBottle: total / Decimal(bottles.count),
                        paidPerBottle: paid.isEmpty ? nil : paid.reduce(Decimal(0), +) / Decimal(paid.count))
        }
        .sorted { $0.total != $1.total ? $0.total > $1.total : Wine.alphabeticalOrder($0.wine, $1.wine) }
        return CellarReportSection(scope: scope, lines: lines)
    }
}

/// Renders a one-or-more page PDF report of the cellar: totals up top, then each
/// location (collection), most valuable first, with a line per wine (vintage/name,
/// count, rating, price per bottle, price paid per bottle, estimated value).
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
        let sectionAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 14)]
        let headerAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 10),
            .foregroundColor: UIColor.gray]
        let nameStyle = NSMutableParagraphStyle()
        nameStyle.lineBreakMode = .byTruncatingTail
        let rowAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .paragraphStyle: nameStyle]
        let numAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.darkGray]
        let totalAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]

        // Right edges of the number columns; the name column fills the rest.
        let right = pageRect.width - margin
        let totalRight = right
        let paidRight = right - 84
        let perBottleRight = paidRight - 76
        let qtyRight = perBottleRight - 76
        let nameWidth = qtyRight - 30 - margin

        func drawRight(_ text: String, _ edge: CGFloat, _ y: CGFloat, _ attr: [NSAttributedString.Key: Any]) {
            let w = (text as NSString).size(withAttributes: attr).width
            text.draw(at: CGPoint(x: edge - w, y: y), withAttributes: attr)
        }

        let sections = CellarReportSection.sections(for: wines)
        let showSectionHeaders = !(sections.count == 1 && sections.first.map {
            if case .all = $0.scope { return true } else { return false }
        } == true)

        try renderer.writePDF(to: url) { ctx in
            var y: CGFloat = margin
            ctx.beginPage()

            "Cellar Report".draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttr)
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

            // A total per location, most valuable first.
            if showSectionHeaders {
                for section in sections {
                    "\(section.scope.title): \(section.bottleCount) bottle(s) · \(Money.string(section.total))"
                        .draw(at: CGPoint(x: margin, y: y), withAttributes: subAttr)
                    y += 16
                }
                y += 8
            }

            func columnHeaders() {
                "WINE".draw(at: CGPoint(x: margin, y: y), withAttributes: headerAttr)
                drawRight("QTY", qtyRight, y, headerAttr)
                drawRight("PER BOTTLE", perBottleRight, y, headerAttr)
                drawRight("PAID / BTL", paidRight, y, headerAttr)
                drawRight("VALUE", totalRight, y, headerAttr)
                y += 16
            }

            for section in sections {
                // Keep a section's title, column headers and first row together.
                if y > pageRect.height - margin - 60 {
                    ctx.beginPage()
                    y = margin
                }
                y += 6
                if showSectionHeaders {
                    section.scope.title.draw(at: CGPoint(x: margin, y: y), withAttributes: sectionAttr)
                    drawRight(Money.string(section.total), totalRight, y + 2, totalAttr)
                    y += 22
                }
                columnHeaders()

                for line in section.lines {
                    if y > pageRect.height - margin {
                        ctx.beginPage()
                        y = margin
                        columnHeaders()
                    }
                    var name = line.wine.displayTitle
                    if let r = line.wine.rating, r > 0 { name += "  \(r)★" }
                    else if let s = line.wine.communityScore { name += "  \(s)pt" }
                    name.draw(with: CGRect(x: margin, y: y, width: nameWidth, height: 16),
                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                              attributes: rowAttr, context: nil)
                    drawRight("×\(line.count)", qtyRight, y, numAttr)
                    drawRight(line.perBottle > 0 ? Money.string(line.perBottle) : "—", perBottleRight, y, numAttr)
                    drawRight(line.paidPerBottle.map { Money.string($0) } ?? "—", paidRight, y, numAttr)
                    drawRight(Money.string(line.total), totalRight, y, totalAttr)
                    y += 18
                }
                y += 10
            }
        }
        return url
    }
}
