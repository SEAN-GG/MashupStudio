import SwiftUI

struct HomeView: View {
    @State private var store = ProjectStore.shared
    @State private var openedProject: MixProject?
    @State private var renameTarget: ProjectSummary?
    @State private var renameText = ""
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if store.summaries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.summaries) { summary in
                                ProjectCard(summary: summary) {
                                    cardMenu(summary)
                                }
                                .onTapGesture { open(summary) }
                                .contextMenu { cardMenu(summary) }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("הפרויקטים שלי")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openedProject = store.newProject()
                    } label: {
                        Label("פרויקט חדש", systemImage: "plus")
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fullScreenCover(item: $openedProject) { project in
            EditorView(project: project) {
                openedProject = nil
                store.refresh()
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .alert("שינוי שם", isPresented: Binding(get: { renameTarget != nil },
                                                set: { if !$0 { renameTarget = nil } })) {
            TextField("שם הפרויקט", text: $renameText)
            Button("שמירה") {
                if let target = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.rename(target.id, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                renameTarget = nil
            }
            Button("ביטול", role: .cancel) { renameTarget = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("עדיין אין פרויקטים")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("צור פרויקט חדש, הוסף שירים, ובנה מחרוזת עם מעברים משלך")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                openedProject = store.newProject()
            } label: {
                Label("פרויקט חדש", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(32)
    }

    private func open(_ summary: ProjectSummary) {
        if let project = store.load(summary.id) {
            openedProject = project
        }
    }

    @ViewBuilder
    private func cardMenu(_ summary: ProjectSummary) -> some View {
        Button {
            renameTarget = summary
            renameText = summary.name
        } label: {
            Label("שינוי שם", systemImage: "pencil")
        }
        Button {
            store.duplicate(summary.id)
        } label: {
            Label("שכפול הפרויקט", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            store.delete(summary.id)
        } label: {
            Label("מחיקה", systemImage: "trash")
        }
    }
}

private struct ProjectCard<MenuContent: View>: View {
    let summary: ProjectSummary
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle().inset(by: -8))
                }
                if summary.isDraft {
                    Text("טיוטה")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.22), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 8)
            Text(summary.name)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Label(TimeFormat.short(summary.duration), systemImage: "clock")
                Label("\(summary.clipCount)", systemImage: "square.stack.3d.down.forward")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            Text(summary.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(14)
        .frame(minHeight: 140, alignment: .topTrailing)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
    }
}
