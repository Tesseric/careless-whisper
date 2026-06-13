import SwiftUI

/// Collapsed, always-visible state of the persistent git overlay: a GitHub-style diffstat
/// pill (branch + "+A −R · N files" + a 5-cell red/green ratio bar). Tapping toggles expand.
struct DiffStatPill: View {
    let branch: String
    let scope: DiffStatScope
    let onTap: () -> Void

    private var added: Int { scope.total.added }
    private var removed: Int { scope.total.removed }
    private var files: Int { scope.total.files }

    /// Number of green cells out of 5, proportional to added/(added+removed).
    private var greenCells: Int {
        let denom = added + removed
        guard denom > 0 else { return 0 }
        return max(added > 0 ? 1 : 0, Int((Double(added) / Double(denom) * 5).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                Text(branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.74, green: 0.58, blue: 0.98)) // dracula purple
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text("+\(added)")
                    .foregroundStyle(.green)
                Text("−\(removed)")
                    .foregroundStyle(.red)
                Text("· \(files) file\(files == 1 ? "" : "s")")
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))

            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(cellColor(i))
                        .frame(width: 9, height: 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.157, green: 0.165, blue: 0.212)) // dracula bg #282a36
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func cellColor(_ index: Int) -> Color {
        if added == 0 && removed == 0 { return Color.white.opacity(0.18) }
        return index < greenCells ? .green : .red
    }
}
