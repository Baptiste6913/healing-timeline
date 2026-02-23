import SwiftUI

struct TimelineControlView: View {
    @ObservedObject var viewModel: ViewerViewModel

    private let presetDays: [(String, Float)] = [
        ("Day 1", 1),
        ("Day 3", 3),
        ("1 wk", 7),
        ("2 wk", 14),
        ("1 mo", 30),
        ("3 mo", 90),
        ("6 mo", 180),
        ("1 yr", 365),
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Continuous slider
            VStack(spacing: 4) {
                Slider(
                    value: $viewModel.sliderDay,
                    in: 0...365,
                    step: 1
                )
                .tint(.cyan)
                .onChange(of: viewModel.sliderDay) { _, newVal in
                    viewModel.setDay(Float(newVal))
                }

                HStack {
                    Text("Surgery")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("12 months")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }

            // Preset buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presetDays, id: \.1) { label, day in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                viewModel.sliderDay = Double(day)
                                viewModel.setDay(day)
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 13, weight: isSelected(day) ? .bold : .medium))
                                .foregroundColor(isSelected(day) ? .white : .gray)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected(day)
                                    ? AnyShapeStyle(.linearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.1))
                                )
                                .cornerRadius(20)
                        }
                    }
                }
            }

            // Range toggle
            HStack {
                Toggle("Show range (min/max)", isOn: $viewModel.showRange)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .tint(.cyan)
            }
        }
        .padding(.vertical, 8)
    }

    private func isSelected(_ day: Float) -> Bool {
        abs(viewModel.sliderDay - Double(day)) < 1
    }
}
