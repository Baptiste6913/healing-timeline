import SwiftUI

struct SettingsView: View {
    @Binding var profile: HealingProfile
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Skin Thickness", selection: $profile.skinThickness) {
                        ForEach(HealingProfile.SkinThickness.allCases, id: \.self) { t in
                            Text(t.rawValue.capitalized).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Thicker skin typically results in longer-lasting swelling, especially at the nasal tip.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } header: {
                    Text("Skin Type")
                }

                Section {
                    Picker("Initial Intensity", selection: $profile.initialIntensity) {
                        ForEach(HealingProfile.Intensity.allCases, id: \.self) { i in
                            Text(i.rawValue.capitalized).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Expected Swelling Level")
                }

                Section {
                    Toggle("Show Bruising", isOn: $profile.bruisingPresent)
                } header: {
                    Text("Ecchymosis (Bruising)")
                }

                Section {
                    HStack {
                        Text("Age (optional)")
                        Spacer()
                        TextField("Age", value: $profile.age, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    Text("Age has a minor effect on recovery speed.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Section {
                    Text("⚠ This simulation is for illustrative purposes only. Individual results vary. Always consult your surgeon.")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                } header: {
                    Text("Disclaimer")
                }
            }
            .navigationTitle("Simulation Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
