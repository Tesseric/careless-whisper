import SwiftUI

/// Which diff scope the expanded overlay is showing.
enum DiffScope: String { case branch, working }

/// Expanded state of the persistent git overlay: diffstat header + Tests/Functional/Other
/// breakdown + the reused (trimmed) GitContextView + the agent annotation zone.
struct GitOverlayExpandedView: View {
    let context: GitContext
    let scope: DiffScope
    let annotation: GitAnnotation?
    let onToggleScope: (DiffScope) -> Void
    let onCollapse: () -> Void
    let onClose: () -> Void

    /// The active scope's stats. Falls back to working when branch stats are absent
    /// (e.g. on the default branch).
    private var activeScope: DiffStatScope {
        guard let stats = context.diffStats else { return DiffStatScope() }
        switch scope {
        case .working: return stats.working
        case .branch:  return stats.branch ?? stats.working
        }
    }

    private var branchScopeAvailable: Bool { context.diffStats?.branch != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            DiffStatHeaderView(scope: activeScope)
            TestFunctionalBreakdownView(scope: activeScope)
            Divider().overlay(Color.white.opacity(0.1))
            GitContextView(context: context, showDiffPreviews: false)
            if let annotation, hasContent(annotation) {
                GitAnnotationView(annotation: annotation)
            }
        }
        .padding(13)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.157, green: 0.165, blue: 0.212))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
            Text(context.branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.74, green: 0.58, blue: 0.98))
                .lineLimit(1)
            Spacer()
            if branchScopeAvailable {
                scopeToggle
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var scopeToggle: some View {
        HStack(spacing: 0) {
            segment("Branch", .branch)
            segment("Working", .working)
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.18)))
    }

    private func segment(_ label: String, _ value: DiffScope) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(scope == value ? Color(red: 0.74, green: 0.58, blue: 0.98) : .clear)
            .foregroundStyle(scope == value ? Color.black.opacity(0.85) : .white.opacity(0.45))
            .contentShape(Rectangle())
            .onTapGesture { onToggleScope(value) }
    }

    private func hasContent(_ a: GitAnnotation) -> Bool {
        (a.summary?.isEmpty == false) || a.risk != nil || (a.highlights?.isEmpty == false)
    }
}

/// The "+A −R · N files" line plus the 5-cell ratio bar (expanded header).
private struct DiffStatHeaderView: View {
    let scope: DiffStatScope

    var body: some View {
        let t = scope.total
        let denom = t.added + t.removed
        let green = denom > 0 ? max(t.added > 0 ? 1 : 0, Int((Double(t.added) / Double(denom) * 10).rounded())) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("+\(t.added)").foregroundStyle(.green)
                Text("−\(t.removed)").foregroundStyle(.red)
                Text("· \(t.files) file\(t.files == 1 ? "" : "s")").foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(denom == 0 ? Color.white.opacity(0.18) : (i < green ? .green : .red))
                        .frame(width: 11, height: 8)
                }
            }
        }
    }
}

/// Three proportional bars: Functional / Tests / Other, each with its own +/− counts.
private struct TestFunctionalBreakdownView: View {
    let scope: DiffStatScope

    var body: some View {
        let maxTotal = max(1, [scope.functional, scope.test, scope.other]
            .map { $0.added + $0.removed }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("TESTS vs FUNCTIONAL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            bar("Functional", scope.functional, .cyan, maxTotal)
            bar("Tests", scope.test, Color(red: 0.74, green: 0.58, blue: 0.98), maxTotal)
            bar("Other", scope.other, .orange, maxTotal)
        }
    }

    private func bar(_ label: String, _ count: LineCount, _ color: Color, _ maxTotal: Int) -> some View {
        let value = count.added + count.removed
        let frac = CGFloat(value) / CGFloat(maxTotal)
        return HStack(spacing: 7) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.8))
                        .frame(width: max(0, geo.size.width * frac))
                }
            }
            .frame(height: 7)
            Text("+\(count.added) −\(count.removed)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 70, alignment: .trailing)
        }
    }
}

/// Agent annotation zone: risk badge + summary + highlight lines. Purple-bordered.
struct GitAnnotationView: View {
    let annotation: GitAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("◆ AGENT SUMMARY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(red: 0.74, green: 0.58, blue: 0.98))
                Spacer()
                if let risk = annotation.risk {
                    Text("RISK: \(risk.rawValue.uppercased())")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(riskColor(risk).opacity(0.18))
                        .foregroundStyle(riskColor(risk))
                        .clipShape(Capsule())
                }
            }
            if let summary = annotation.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(annotation.highlights ?? [], id: \.self) { line in
                Text("⚠ \(line)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.74, green: 0.58, blue: 0.98).opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(red: 0.74, green: 0.58, blue: 0.98), lineWidth: 1)
        )
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}
