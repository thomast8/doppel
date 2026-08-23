import SwiftUI

struct LiveSwitchMenuSection: View {
    let instance: Instance
    @ObservedObject var controller: LiveSwitchController

    var body: some View {
        Button(action: toggle) {
            Label(
                "Live model/reasoning switching (Experimental)",
                systemImage: controller.isEnabled(for: instance) ? "checkmark" : "circle")
        }
        if controller.isEnabled(for: instance) {
            let status = controller.status(for: instance)
            Label(status.label, systemImage: status.systemImage)
                .disabled(true)
            Text("Active picker changes stop and continue the current task.")
        }
    }

    private func toggle() {
        controller.toggle(for: instance)
    }
}
