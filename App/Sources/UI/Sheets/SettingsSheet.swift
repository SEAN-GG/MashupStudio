import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    var body: some View {
        NavigationStack {
            List {
                Section("תצוגת סולמות") {
                    Picker("שיטת סימון", selection: Binding(
                        get: { settings.keyNotation },
                        set: { settings.setKeyNotation($0) }
                    )) {
                        ForEach(KeyNotationStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text("דוגמה: הסולם לה מינור יוצג כ־8A (קמלוט) או Am (מז'ור/מינור)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Section("עריכה") {
                    Toggle("הצמדה (Snap) בגרירה", isOn: Binding(
                        get: { settings.snapEnabled },
                        set: { settings.setSnapEnabled($0) }
                    ))
                    Toggle("הצמדה לביטים של שירים", isOn: Binding(
                        get: { settings.snapToBeats },
                        set: { settings.setSnapToBeats($0) }
                    ))
                    Toggle("מעקב אחרי נקודת הנגינה", isOn: Binding(
                        get: { settings.followPlayhead },
                        set: { settings.setFollowPlayhead($0) }
                    ))
                    HStack {
                        Text("קרוספייד ברירת מחדל")
                        Slider(value: Binding(
                            get: { settings.defaultCrossfade },
                            set: { settings.setDefaultCrossfade($0) }
                        ), in: 2...20, step: 1)
                        Text("\(Int(settings.defaultCrossfade)) שנ׳")
                            .monospacedDigit()
                            .frame(width: 46)
                    }
                }
                Section("אודות") {
                    HStack {
                        Text("גרסה")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("סטודיו מיקס — עריכת שירים, מיקסים ומחרוזות עם מעברים חכמים.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגירה") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
