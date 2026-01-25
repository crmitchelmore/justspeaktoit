# Copilot Instructions

Project-specific patterns and conventions for AI-assisted development.

## SwiftUI Concurrency Patterns

### Singleton ObservableObjects
- Use `@ObservedObject` (not `@StateObject`) when referencing singletons like `TipStore.shared`
- Singletons manage their own lifecycle; `@StateObject` causes ownership conflicts and crashes

### Child View Button Actions
- Don't pass `@ObservedObject` to child views that have button actions
- Pass primitive values (e.g., `isPurchasing: Bool`) and access singleton directly in action:
  ```swift
  Button {
      Task { @MainActor in
          await MySingleton.shared.doWork()
      }
  }
  ```

### Async Delays in SwiftUI
- Prefer `.task { try? await Task.sleep(for: .seconds(2)) }` over `DispatchQueue.asyncAfter`
- The `.task` modifier properly handles view lifecycle and cancellation
