import SwiftUI

struct TechTreeView: View {
    @Bindable var gameState: GameState
    @Binding var hoveredInfo: String

    // ── Grid metrics ──────────────────────────────────────────────────────────
    private let cardW:   CGFloat = 148
    private let cardH:   CGFloat = 52
    private let colStep: CGFloat = 162
    private let rowStep: CGFloat = 70
    private let lPad:    CGFloat = 20
    private let tPad:    CGFloat = 14

    // ── Explicit position map (col, row) per node ─────────────────────────────
    // Column = dependency depth (deeper prereqs → further right unlock).
    // Gaps between row groups leave room for future non-tower upgrades.
    private static let grid: [TechNodeID: (col: Int, row: Int)] = {
        var g: [TechNodeID: (col: Int, row: Int)] = [:]

        // Row 0 — Sword (always free, root)
        g[.towerUnlock(.sword)] = (0, 0)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.sword, lv)] = (lv - 1, 0) }

        // Row 1 — Base tower upgrades (always accessible, no unlock gate)
        for lv in 2...6 { g[.baseTowerLevel(lv)] = (lv - 2, 1) }

        // Row 2 — Projectile (root unlock)
        g[.towerUnlock(.projectile)] = (0, 2)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.projectile, lv)] = (lv - 1, 2) }

        // Rows 3–5 — towers that need Projectile (col 1 = one step deeper)
        g[.towerUnlock(.bowler)] = (1, 3)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.bowler, lv)] = (lv, 3) }

        g[.towerUnlock(.laser)] = (1, 4)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.laser, lv)] = (lv, 4) }

        g[.towerUnlock(.fire)] = (1, 5)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.fire, lv)] = (lv, 5) }

        // Row 6 — Starting gold upgrades
        for lv in 1...5 { g[.startingGold(lv)] = (lv - 1, 6) }

        // Row 7 — Fireball (needs Laser + Fire, col 3 = two steps deeper)
        g[.towerUnlock(.fireball)] = (3, 7)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.fireball, lv)] = (lv + 2, 7) }

        // Row 8 — Lightning (needs Projectile, one step deeper)
        g[.towerUnlock(.lightning)] = (1, 8)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.lightning, lv)] = (lv, 8) }

        // Row 9 — Farm (root) + Ice on same row
        g[.farmUnlock] = (0, 9)
        g[.towerUnlock(.ice)] = (1, 9)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.ice, lv)] = (lv, 9) }

        // Row 10 — Global targeting upgrades (independent category)
        for feat in 1...5 { g[.targetingFeature(feat)] = (feat - 1, 10) }

        // Row 11 — Anti-air (farm child)
        g[.towerUnlock(.antiAir)] = (1, 11)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.antiAir, lv)] = (lv, 11) }

        // Row 13 — Healer (needs Targeting, col 3)   [row 12 open for general upgrade]
        g[.towerUnlock(.healer)] = (3, 13)
        for lv in 2...Tower.maxLevel { g[.towerLevel(.healer, lv)] = (lv + 2, 13) }

        return g
    }()

    // ── Coordinate helpers ────────────────────────────────────────────────────
    private func colX(_ c: Int) -> CGFloat { lPad + CGFloat(c) * colStep }
    private func rowY(_ r: Int) -> CGFloat { tPad + CGFloat(r) * rowStep }
    private func center(col: Int, row: Int) -> CGPoint {
        CGPoint(x: colX(col) + cardW / 2, y: rowY(row) + cardH / 2)
    }
    private func nodeCenter(_ id: TechNodeID) -> CGPoint? {
        guard let p = Self.grid[id] else { return nil }
        return center(col: p.col, row: p.row)
    }

    private var canvasW: CGFloat {
        let maxCol = Self.grid.values.map { $0.col }.max() ?? 0
        return lPad + CGFloat(maxCol + 1) * colStep + lPad
    }
    private var canvasH: CGFloat {
        let maxRow = Self.grid.values.map { $0.row }.max() ?? 0
        return tPad + CGFloat(maxRow + 1) * rowStep + tPad
    }

    // ── Visibility ────────────────────────────────────────────────────────────
    // Show a node whenever all its prerequisites are owned (regardless of cost).
    // Nodes with no prerequisites (Projectile, Farm, Sword levels) are always visible.
    private func shouldShow(_ id: TechNodeID) -> Bool {
        if case .baseTowerLevel(2) = id { return true }
        if case .startingGold(1) = id { return true }
        if gameState.purchasedTechNodes.contains(id) { return true }
        guard let def = GameState.techNodes.first(where: { $0.id == id }) else { return false }
        let owned = gameState.purchasedTechNodes.union([.towerUnlock(.sword)])
        return def.prerequisites.allSatisfy { owned.contains($0) }
    }

    // Stable ordered list for ForEach (sorted by row, then col)
    private var nonSwordNodes: [TechNodeID] {
        Self.grid.keys
            .filter { $0 != .towerUnlock(.sword) }
            .sorted {
                let a = Self.grid[$0]!, b = Self.grid[$1]!
                return a.row != b.row ? a.row < b.row : a.col < b.col
            }
    }

    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    // ── Body ──────────────────────────────────────────────────────────────────
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.09)
                ZStack(alignment: .topLeading) {
                    edgeCanvas
                    if let pos = Self.grid[.towerUnlock(.sword)] {
                        SwordFreeCard(hoveredInfo: $hoveredInfo)
                            .frame(width: cardW, height: cardH)
                            .position(center(col: pos.col, row: pos.row))
                    }
                    ForEach(nonSwordNodes.filter { shouldShow($0) }, id: \.self) { id in
                        if let pos = Self.grid[id] {
                            NodeCard(id: id, gameState: gameState, hoveredInfo: $hoveredInfo)
                                .frame(width: cardW, height: cardH)
                                .position(center(col: pos.col, row: pos.row))
                        }
                    }
                }
                .frame(width: canvasW, height: canvasH)
                .offset(panOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        panOffset = CGSize(
                            width: lastPanOffset.width + value.translation.width,
                            height: lastPanOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in lastPanOffset = panOffset }
            )
            .onAppear {
                // Shift so the canvas top is near the top of the view,
                // and horizontally centered on the node columns.
                let offsetX = (canvasW - geo.size.width) / 2
                let offsetY = (canvasH - geo.size.height) / 2
                panOffset = CGSize(width: -offsetX + lPad, height: -offsetY + tPad)
                lastPanOffset = panOffset
            }
        }
    }

    // ── Edges ─────────────────────────────────────────────────────────────────
    private var edgeCanvas: some View {
        Canvas { ctx, _ in
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .square, lineJoin: .miter)

            func edgeColor(from: TechNodeID, to: TechNodeID) -> Color {
                let srcOwned = from == .towerUnlock(.sword)
                    || gameState.purchasedTechNodes.contains(from)
                let dstOwned = gameState.purchasedTechNodes.contains(to)
                return srcOwned && dstOwned
                    ? Color(white: 0.70).opacity(0.80)
                    : Color(white: 0.46).opacity(0.28)
            }

            func drawEdge(from: TechNodeID, to: TechNodeID) {
                guard let a = nodeCenter(from), let b = nodeCenter(to),
                      let srcPos = Self.grid[from], let dstPos = Self.grid[to] else { return }
                let srcVis = from == .towerUnlock(.sword) || shouldShow(from)
                guard srcVis && shouldShow(to) else { return }

                let color = edgeColor(from: from, to: to)
                var p = Path()

                if abs(a.y - b.y) < 4 {
                    // Same row: horizontal between card edges
                    p.move(to: CGPoint(x: a.x + cardW / 2, y: a.y))
                    p.addLine(to: CGPoint(x: b.x - cardW / 2, y: b.y))
                } else {
                    // Cross-row: L-route through midpoint between source and dest columns.
                    // The vertical segment sits in the gap between the two columns.
                    let srcRight = colX(srcPos.col) + cardW
                    let dstLeft  = colX(dstPos.col)
                    let lx = srcRight + (dstLeft - srcRight) * 0.45
                    p.move(to: CGPoint(x: a.x + cardW / 2, y: a.y))
                    p.addLine(to: CGPoint(x: lx, y: a.y))
                    p.addLine(to: CGPoint(x: lx, y: b.y))
                    p.addLine(to: CGPoint(x: b.x - cardW / 2, y: b.y))
                }
                ctx.stroke(p, with: .color(color), style: style)
            }

            for def in GameState.techNodes {
                for prereq in def.prerequisites { drawEdge(from: prereq, to: def.id) }
            }
            // Sword → Lv2 has no prereq in data since sword is free
            drawEdge(from: .towerUnlock(.sword), to: .towerLevel(.sword, 2))
        }
        .frame(width: canvasW, height: canvasH)
    }
}

// MARK: - Node Card

private struct NodeCard: View {
    let id: TechNodeID
    @Bindable var gameState: GameState
    @Binding var hoveredInfo: String

    var body: some View {
        let purchased = gameState.purchasedTechNodes.contains(id)
        let canBuy    = gameState.canPurchase(id)
        let def       = GameState.techNodes.first { $0.id == id }

        Button { if canBuy { gameState.purchase(id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    Text(def?.title ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(purchased || canBuy ? 1.0 : 0.42))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    if purchased {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                }
                Text(statusLine(purchased: purchased, canBuy: canBuy, def: def))
                    .font(.system(size: 10))
                    .foregroundColor(purchased ? .green.opacity(0.75) : canBuy ? .yellow : .white.opacity(0.28))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.17))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: canBuy ? 0.65 : 0.26), lineWidth: canBuy ? 1.5 : 1.0))
            )
        }
        .buttonStyle(.plain)
        .help(tooltip(purchased: purchased, canBuy: canBuy, def: def))
        .onHover { hovering in
            hoveredInfo = hovering ? tooltip(purchased: purchased, canBuy: canBuy, def: def) : ""
        }
    }

    private func statusLine(purchased: Bool, canBuy: Bool, def: TechNodeDef?) -> String {
        guard let def else { return "" }
        let pts = "\(def.cost) pt\(def.cost == 1 ? "" : "s")"
        if purchased { return "Purchased" }
        return canBuy ? pts : "\(pts) · locked"
    }

    private func tooltip(purchased: Bool, canBuy: Bool, def: TechNodeDef?) -> String {
        guard let def else { return "" }
        let status: String
        if purchased {
            status = "Purchased"
        } else {
            let pts = "\(def.cost) point\(def.cost == 1 ? "" : "s")"
            status = canBuy ? pts : "\(pts) · locked until prerequisites are purchased"
        }
        let header = "\(def.title) (\(status))"
        return def.description.isEmpty ? header : "\(header) — \(def.description)"
    }
}

// MARK: - Sword Free Card

private struct SwordFreeCard: View {
    @Binding var hoveredInfo: String

    private static let tooltip = "Sword Tower (Always free) — Always-unlocked melee tower. Short range but hits hard, and swipes multiple enemies at max level."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("Sword Tower")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundColor(.green)
            }
            Text("Always free")
                .font(.system(size: 10)).foregroundColor(.green.opacity(0.75))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.17))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(white: 0.26), lineWidth: 1.0))
        )
        .help(Self.tooltip)
        .onHover { hovering in
            hoveredInfo = hovering ? Self.tooltip : ""
        }
    }
}
