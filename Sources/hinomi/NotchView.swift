import HinomiCore
import SwiftUI

enum NotchLayout {
    static let collapsedSize = CGSize(width: 132, height: 26)
    static let expandedWidth: CGFloat = 404
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 56
    static let maxRows = 6
    static let verticalPadding: CGFloat = 8

    static func expandedSize(rowCount: Int) -> CGSize {
        let rows = max(1, min(rowCount, maxRows))
        let extra: CGFloat = rowCount > maxRows ? 18 : 0
        return CGSize(width: expandedWidth,
                      height: headerHeight + CGFloat(rows) * rowHeight + verticalPadding * 2 + extra)
    }
}

/// 上端は画面最上部（メニューバー）に接するので、下側だけ丸めたノッチ風の形。
private func notchShape(radius: CGFloat) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 0,
                           bottomLeadingRadius: radius,
                           bottomTrailingRadius: radius,
                           topTrailingRadius: 0,
                           style: .continuous)
}

private extension SessionState {
    var tint: Color {
        switch self {
        case .awaitingPermission: return Color(red: 1.0, green: 0.58, blue: 0.20)
        case .awaitingInput: return Color(red: 1.0, green: 0.84, blue: 0.30)
        case .working: return Color(red: 0.36, green: 0.85, blue: 0.53)
        case .done: return Color(red: 0.45, green: 0.68, blue: 1.0)
        case .idle: return Color(white: 0.55)
        }
    }
}

struct NotchView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        Group {
            if model.expanded {
                expanded
            } else {
                collapsed
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 畳んだ表示

    private var collapsed: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.58, blue: 0.20))
            Text("\(model.sessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            HStack(spacing: 3) {
                ForEach(model.sessions.prefix(6)) { session in
                    Circle()
                        .fill(session.state.tint)
                        .frame(width: 6, height: 6)
                }
            }
            if model.sessions.isEmpty {
                Text("hinomi")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NotchLayout.collapsedSize.height)
        .background(
            notchShape(radius: 13).fill(Color.black.opacity(0.86))
        )
        .overlay(
            notchShape(radius: 13).stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .frame(width: NotchLayout.collapsedSize.width, height: NotchLayout.collapsedSize.height)
    }

    // MARK: - 展開表示

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.sessions.isEmpty {
                Text("稼働中のセッションはありません")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.55))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: NotchLayout.rowHeight)
            } else {
                ForEach(model.sessions.prefix(NotchLayout.maxRows)) { session in
                    SessionRow(session: session, model: model)
                        .frame(height: NotchLayout.rowHeight)
                }
                if model.sessions.count > NotchLayout.maxRows {
                    Text("ほか \(model.sessions.count - NotchLayout.maxRows) 件")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.5))
                        .padding(.leading, 12)
                        .frame(height: 18, alignment: .leading)
                }
            }
        }
        .padding(.vertical, NotchLayout.verticalPadding)
        .frame(width: NotchLayout.expandedWidth, alignment: .top)
        .background(
            notchShape(radius: 16).fill(Color.black.opacity(0.92))
        )
        .overlay(
            notchShape(radius: 16).stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.58, blue: 0.20))
            Text("hinomi")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Text("稼働 \(model.busyCount) / 全 \(model.sessions.count)")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.55))
            Spacer()
            Text("行クリックでターミナルへ")
                .font(.system(size: 9))
                .foregroundColor(Color(white: 0.42))
        }
        .padding(.horizontal, 12)
        .frame(height: NotchLayout.headerHeight)
    }
}

private struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var model: SessionsModel

    private var isHighlighted: Bool { model.highlighted == session.id }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(session.state.tint)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // 見出しは「いま何をさせているか」（直近プロンプト）。無ければプロジェクト名
                    Text(session.title ?? session.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if session.title != nil {
                        Text(session.projectName)
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.5))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Text(session.state.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(session.state.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(session.state.tint.opacity(0.16)))
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    Text(session.elapsedText(now: model.now))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(Color(white: 0.55))
                    if let terminal = TerminalCatalog.shortName(forTermProgram: session.termProgram) {
                        Text(terminal)
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.45))
                            .lineLimit(1)
                    }
                }
                if let pending = session.pending {
                    permissionControls(pending: pending)
                } else {
                    Text(session.activity)
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? session.state.tint.opacity(0.13) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.jump(to: session) }
    }

    private func permissionControls(pending: PendingPermission) -> some View {
        HStack(spacing: 6) {
            Text(pending.summary)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.72))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                model.answer(session: session, with: .allow)
            } label: {
                pill(text: "許可", color: Color(red: 0.36, green: 0.85, blue: 0.53))
            }
            .buttonStyle(.plain)
            Button {
                model.answer(session: session, with: .deny)
            } label: {
                pill(text: "拒否", color: Color(red: 1.0, green: 0.42, blue: 0.42))
            }
            .buttonStyle(.plain)
            Text("\(pending.remainingSeconds(now: model.now))s")
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(Color(white: 0.5))
                .frame(width: 22, alignment: .trailing)
        }
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
    }
}
