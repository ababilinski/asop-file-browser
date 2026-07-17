import SwiftUI

struct SortPriorityBadge: View {
    let priority: Int

    var body: some View {
        if priority > 1 {
            Text("\(priority)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.accentColor))
                .accessibilityLabel("Sort priority \(priority)")
        }
    }
}
