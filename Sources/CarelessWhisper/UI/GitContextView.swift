import SwiftUI

// MARK: - Git Context View

struct GitContextView: View {
    let context: GitContext
    var showDiffPreviews: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Repo / branch + ahead/behind
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))

                Text(context.repoName)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))

                Text("/")
                    .foregroundStyle(.white.opacity(0.4))

                Text(context.branch)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                if let ab = context.aheadBehind, ab.ahead > 0 || ab.behind > 0 {
                    Spacer()
                    HStack(spacing: 4) {
                        if ab.ahead > 0 {
                            Text("↑\(ab.ahead)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.7))
                        }
                        if ab.behind > 0 {
                            Text("↓\(ab.behind)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange.opacity(0.7))
                        }
                    }
                }
            }

            // Last commit
            if let commit = context.lastCommit {
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(commit.relativeTime)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            // CI + PR status
            if context.ciStatus != nil || context.prInfo != nil {
                HStack(spacing: 8) {
                    if let ci = context.ciStatus {
                        CIBadgeView(ci: ci)
                    }
                    if let pr = context.prInfo {
                        PRBadgeView(pr: pr)
                    }
                }
            }

            // File sections
            if !context.stagedFiles.isEmpty || !context.unstagedFiles.isEmpty || !context.branchFiles.isEmpty {
                GitStatusView(staged: context.stagedFiles, unstaged: context.unstagedFiles, branch: context.branchFiles)
            }

            // Stash count
            if context.stashCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("\(context.stashCount) stash\(context.stashCount == 1 ? "" : "es")")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            // Diff previews
            if showDiffPreviews {
                ForEach(Array(context.diffPreviews.enumerated()), id: \.offset) { _, diff in
                    DiffPreviewView(preview: diff)
                }
            }
        }
    }
}

// MARK: - Git Status View

struct GitStatusView: View {
    let staged: [GitFileChange]
    let unstaged: [GitFileChange]
    let branch: [GitFileChange]

    private let maxFiles = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !branch.isEmpty {
                fileSection("Branch", files: branch, dotColor: .blue)
            }
            if !staged.isEmpty {
                fileSection("Staged", files: staged, dotColor: .green)
            }
            if !unstaged.isEmpty {
                fileSection("Changes", files: unstaged, dotColor: .orange)
            }
        }
    }

    private func fileSection(_ title: String, files: [GitFileChange], dotColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text("\(title) · \(files.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            ForEach(Array(files.prefix(maxFiles).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 6) {
                    Text(file.type.letter)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file.type))
                        .frame(width: 12, alignment: .center)

                    Text(file.displayName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 11)
            }

            if files.count > maxFiles {
                Text("+\(files.count - maxFiles) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 11)
            }
        }
    }

    private func statusColor(_ type: FileChangeType) -> Color {
        switch type {
        case .added:     return .green
        case .modified:  return .cyan
        case .deleted:   return .red
        case .renamed:   return .purple
        case .untracked: return Color.white.opacity(0.4)
        }
    }
}

// MARK: - CI Badge

struct CIBadgeView: View {
    let ci: CIStatus

    var body: some View {
        HStack(spacing: 3) {
            Text(icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        switch ci.state {
        case .success:   return "✓"
        case .failure:   return "✗"
        case .pending:   return "◉"
        case .cancelled: return "⊘"
        case .unknown:   return "●"
        }
    }

    private var label: String {
        switch ci.state {
        case .success:   return "CI passing"
        case .failure:   return "CI failing"
        case .pending:   return "CI running"
        case .cancelled: return "CI cancelled"
        case .unknown:   return "CI"
        }
    }

    private var color: Color {
        switch ci.state {
        case .success:   return .green
        case .failure:   return .red
        case .pending:   return .yellow
        case .cancelled: return .gray
        case .unknown:   return .gray
        }
    }
}

// MARK: - PR Badge

struct PRBadgeView: View {
    let pr: PRInfo

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 9))
                .foregroundStyle(.purple.opacity(0.7))
            Text("#\(pr.number)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text(pr.title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            if let label = reviewLabel {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(reviewColor)
            }
        }
    }

    private var reviewLabel: String? {
        switch pr.reviewDecision {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review needed"
        default: return nil
        }
    }

    private var reviewColor: Color {
        switch pr.reviewDecision {
        case "APPROVED": return .green.opacity(0.7)
        case "CHANGES_REQUESTED": return .orange.opacity(0.7)
        default: return .white.opacity(0.5)
        }
    }
}

// MARK: - Diff Preview

struct DiffPreviewView: View {
    let preview: DiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.fileName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))

            ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                let prefix = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
                let color: Color = line.kind == .added ? .green.opacity(0.7) : line.kind == .removed ? .red.opacity(0.7) : .white.opacity(0.35)
                Text("\(prefix) \(line.text)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Pulse Animation

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.0 : 0.6)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
