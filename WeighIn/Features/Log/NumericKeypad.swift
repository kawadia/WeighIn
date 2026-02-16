import SwiftUI

struct NumericKeypad: View {
    let onTap: (String) -> Void

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(keys, id: \.[0]) { row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            onTap(key)
                        } label: {
                            Text(key)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 43)
                                .background(key == "⌫" ? AppTheme.accentMuted : AppTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}
