import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.language) {
                    Text("language.system").tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("日本語").tag(AppLanguage.japanese)
                } label: {
                    Text("settings.language")
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("settings.language.header")
            } footer: {
                Text("settings.language.footer")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 200)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
