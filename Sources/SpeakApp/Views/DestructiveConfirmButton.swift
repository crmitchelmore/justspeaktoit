import SwiftUI

/// A button that asks for confirmation before running a destructive action.
///
/// It owns its own presentation state so it can be dropped into `View`
/// extensions (the settings tabs are split across extensions and cannot easily
/// add `@State` per button).
struct DestructiveConfirmButton<Label: View>: View {
  private let dialogTitle: String
  private let message: String?
  private let confirmTitle: String
  private let triggerRole: ButtonRole?
  private let action: () -> Void
  private let label: () -> Label

  @State private var isPresentingConfirmation = false

  init(
    dialogTitle: String,
    message: String? = nil,
    confirmTitle: String,
    triggerRole: ButtonRole? = nil,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.dialogTitle = dialogTitle
    self.message = message
    self.confirmTitle = confirmTitle
    self.triggerRole = triggerRole
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(role: triggerRole) {
      isPresentingConfirmation = true
    } label: {
      label()
    }
    .confirmationDialog(
      dialogTitle,
      isPresented: $isPresentingConfirmation,
      titleVisibility: .visible
    ) {
      Button(confirmTitle, role: .destructive, action: action)
      Button("Cancel", role: .cancel) {}
    } message: {
      if let message {
        Text(message)
      }
    }
  }
}

extension DestructiveConfirmButton where Label == Text {
  /// Convenience for a plain titled button, e.g. `Uninstall`.
  init(
    _ title: String,
    dialogTitle: String,
    message: String? = nil,
    confirmTitle: String,
    triggerRole: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.init(
      dialogTitle: dialogTitle,
      message: message,
      confirmTitle: confirmTitle,
      triggerRole: triggerRole,
      action: action,
      label: { Text(title) }
    )
  }
}
