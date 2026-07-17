import SwiftUI

struct MouseUpSelectionGesture: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard abs(value.translation.width) < 4, abs(value.translation.height) < 4 else {
                        return
                    }
                    action()
                }
        )
    }
}

extension View {
    func onMouseUpSelect(_ action: @escaping () -> Void) -> some View {
        modifier(MouseUpSelectionGesture(action: action))
    }
}
