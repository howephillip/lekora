import SwiftUI

/// The menu that slides in from the left of the Agents home (docs/kanban.md): the Board, Schedules, Settings,
/// and later features. Tapping outside it, or swiping it left, closes it.
struct SideMenuView: View {
    @ObservedObject var hosts: HostsModel
    @Binding var isOpen: Bool
    let openBoard: (GatewayClient) -> Void
    let openSchedules: (GatewayClient) -> Void
    let openYourName: () -> Void
    let openInstances: () -> Void
    let manageAgents: (GatewayClient) -> Void

    @GestureState private var drag: CGFloat = 0
    private let width: CGFloat = 300

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                    .accessibilityLabel("Close Menu")
                    .accessibilityAddTraits(.isButton)
                panel
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background {
                        UnevenRoundedRectangle(bottomTrailingRadius: LK.Radius.bubble, topTrailingRadius: LK.Radius.bubble)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.15), radius: 20, x: 4)
                            .ignoresSafeArea(edges: .vertical)
                    }
                    .offset(x: min(0, drag))
                    .gesture(DragGesture(minimumDistance: 12)
                        .updating($drag) { value, state, _ in state = value.translation.width }
                        .onEnded { value in
                            if value.translation.width < -width / 4 || value.predictedEndTranslation.width < -width / 2 { close() }
                        })
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.28), value: isOpen)
    }

    private var panel: some View {
        // The title stays put; the rest scrolls below it (never under the status bar).
        VStack(alignment: .leading, spacing: 0) {
            Text("Lekora")
                .font(LK.Typography.largeTitle)
                .padding(.horizontal, LK.Spacing.lg + LK.Spacing.sm)
                .padding(.top, LK.Spacing.lg)
                .padding(.bottom, LK.Spacing.md)
            ScrollView {
            VStack(alignment: .leading, spacing: LK.Spacing.xl) {
                group(nil) {
                    if hosts.hasSeveral {
                        ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                            item("Board", detail: client.savedHost?.instanceName, symbol: "square.stack.3d.up") { pick { openBoard(client) } }
                        }
                        ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                            item("Schedules", detail: client.savedHost?.instanceName, symbol: "calendar.badge.clock") { pick { openSchedules(client) } }
                        }
                    } else if let client = hosts.clients.first {
                        item("Board", symbol: "square.stack.3d.up") { pick { openBoard(client) } }
                        item("Schedules", symbol: "calendar.badge.clock") { pick { openSchedules(client) } }
                    }
                }
                group("Settings") {
                    item("Your Name", symbol: "person.crop.circle") { pick(openYourName) }
                    item("Hermes Instances", symbol: "server.rack") { pick(openInstances) }
                    if hosts.hasSeveral {
                        // One row; the instance is chosen from it.
                        Menu {
                            ForEach(hosts.clients, id: \.savedHost?.instanceId) { client in
                                Button(client.savedHost?.instanceName ?? "Hermes") { pick { manageAgents(client) } }
                            }
                        } label: {
                            row("Manage Agents", detail: nil, symbol: "person.2")
                        }
                        .buttonStyle(.plain)
                    } else if let client = hosts.clients.first {
                        item("Manage Agents", symbol: "person.2") { pick { manageAgents(client) } }
                    }
                }
            }
            .padding(.horizontal, LK.Spacing.lg)
            .padding(.bottom, LK.Spacing.xxl)
            }
            .scrollBounceBehavior(.basedOnSize)
            .clipped()
        }
    }

    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
            if let title {
                Text(title)
                    .font(LK.Typography.captionStrong)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, LK.Spacing.sm)
                    .padding(.bottom, LK.Spacing.xxs)
            }
            content()
        }
    }

    private func item(_ title: String, detail: String? = nil, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            row(title, detail: detail, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, detail: String?, symbol: String) -> some View {
            HStack(spacing: LK.Spacing.md) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                    .font(.body.weight(.medium))
                    .frame(width: 28)
                    .foregroundStyle(LK.Palette.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(LK.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LK.Spacing.sm)
            .padding(.vertical, LK.Spacing.md)
            .contentShape(Rectangle())
    }

    private func pick(_ action: @escaping () -> Void) {
        close()
        action()
    }

    private func close() {
        isOpen = false
    }
}
