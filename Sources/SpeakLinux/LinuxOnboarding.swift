import Foundation
import CLinuxSupport
import SpeakCore
import SpeakDesktopHost
import SpeakLinuxPlatform

enum LinuxOnboarding {
    static func needsAutomaticSetup(in directory: URL) -> Bool {
        do {
            return try DesktopHostOnboarding.needsOnboardingBeforeLaunch(in: directory)
        } catch {
            FileHandle.standardError.write(Data(("Could not read setup state: \(error.localizedDescription)\n").utf8))
            return false
        }
    }

    static func configure(_ holder: LinuxEventContext) throws {
        guard jsti_setup_configure(linuxSetupEvent, Unmanaged.passUnretained(holder).toOpaque()) == 0 else {
            throw DesktopHostError(message: "The Linux setup guide could not be configured.")
        }
    }

    static func openIfNeeded(_ holder: LinuxEventContext) {
        if holder.needsSetupAtLaunch && !holder.smokeTest && jsti_window_request_setup() != 0 {
            LinuxHostPlatform.update("Setup could not be opened. Use Run setup again in About.")
        }
    }

    static func handle(
        _ command: Int32, index: Int32, action: String, revision: UInt64, holder: LinuxEventContext
    ) async {
        var shown = DesktopOnboardingStep.welcome
        do {
            shown = try step(index, command: command)
            let saved = try await holder.controller.readOnboardingState()
            guard jsti_setup_revision() == revision else { return }
            switch command {
            case 0: await show(saved.resumeStep, revision: revision, holder: holder)
            case 1, 2:
                let target = try await navigate(command, shown: shown, revision: revision, holder: holder)
                await show(target, revision: revision, holder: holder)
            case 3, 4: try await complete(revision: revision, holder: holder)
            case 5:
                try perform(action, for: shown)
                await show(shown, revision: revision, holder: holder)
            case 6: await show(shown, revision: revision, holder: holder)
            default: throw DesktopHostError(message: "Unsupported setup command.")
            }
        } catch {
            await report(error, for: shown, revision: revision, holder: holder)
        }
    }

    private static func step(_ index: Int32, command: Int32) throws -> DesktopOnboardingStep {
        if command == 0 && index == -1 { return .welcome }
        let steps = DesktopOnboardingStep.allCases
        guard steps.indices.contains(Int(index)) else {
            throw DesktopHostError(message: "Invalid setup step.")
        }
        return steps[Int(index)]
    }

    private static func report(
        _ error: Error, for step: DesktopOnboardingStep, revision: UInt64, holder: LinuxEventContext
    ) async {
        guard jsti_setup_revision() == revision else { return }
        let message = "Could not update setup: \(error.localizedDescription)"
        LinuxHostPlatform.update(message)
        await show(step, revision: revision, holder: holder, notice: message)
    }

    private static func navigate(
        _ command: Int32, shown: DesktopOnboardingStep, revision: UInt64, holder: LinuxEventContext
    ) async throws -> DesktopOnboardingStep {
        guard let target = command == 1 ? shown.next : shown.previous else {
            throw DesktopHostError(message: "That setup step is unavailable.")
        }
        try await holder.controller.persistOnboardingStep(
            target, preservingCompletion: !holder.needsSetupAtLaunch,
            checkCancellation: { try checkRevision(revision) }
        )
        return target
    }

    private static func complete(revision: UInt64, holder: LinuxEventContext) async throws {
        try await holder.controller.persistOnboardingState(
            .init(hasCompletedOnboarding: true, lastStep: .done),
            checkCancellation: { try checkRevision(revision) }
        )
        guard jsti_setup_revision() == revision else { return }
        guard jsti_setup_finish(revision) == 0 else {
            throw DesktopHostError(message: "Setup was saved, but its window could not be closed.")
        }
        LinuxHostPlatform.update("Setup is complete. Run it again from About.")
    }

    private static func checkRevision(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard jsti_setup_revision() == revision else { throw CancellationError() }
    }

    private static func perform(_ raw: String, for step: DesktopOnboardingStep) throws {
        guard let action = DesktopOnboardingAction(rawValue: raw), step.actions.contains(action) else {
            throw DesktopHostError(message: "That action does not belong to the current setup step.")
        }
        guard try requestDestination(action) == 0 else {
            throw DesktopHostError(message: "The requested setup destination is unavailable.")
        }
    }

    private static func requestDestination(_ action: DesktopOnboardingAction) throws -> Int32 {
        guard let destination = LinuxOnboardingPage.destination(for: action) else {
            throw DesktopHostError(
                message: "That setup action is unavailable. Practise with the shortcut in another app."
            )
        }
        switch destination {
        case .permissions: return jsti_window_request_permissions()
        case .apiKeys: return jsti_window_request_api_keys()
        case .general: return jsti_window_show_page(Int32(JSTI_PAGE_GENERAL))
        case .transcription: return jsti_window_show_page(Int32(JSTI_PAGE_TRANSCRIPTION))
        case .keyboard: return jsti_window_show_page(Int32(JSTI_PAGE_KEYBOARD))
        case .postProcessing: return jsti_window_show_page(Int32(JSTI_PAGE_POST_PROCESSING))
        }
    }

    private static func status(_ step: DesktopOnboardingStep, holder: LinuxEventContext) async -> String {
        switch step {
        case .microphone, .textInsertion:
            let kind: DesktopPermissionKind = step == .microphone ? .microphone : .textInsertion
            let item = await holder.controller.permissionItems().first { $0.kind == kind }
            return item.map { "\($0.status.label): \($0.detail)" }
                ?? "Check Permissions for desktop-specific guidance."
        case .transcriptionRoute:
            let model = await holder.controller.settings.model
            let name = DesktopHostModels.snapshot.entries.first { $0.option.id == model }?.option.displayName ?? model
            return "\(name) is selected. Use API Keys or Local models to check readiness. "
                + "This guide does not read keys, open the microphone or contact providers."
        default: return await holder.controller.onboardingShortcutHint()
        }
    }

    private static func show(
        _ step: DesktopOnboardingStep, revision: UInt64, holder: LinuxEventContext, notice: String? = nil
    ) async {
        let message = await status(step, holder: holder)
        guard jsti_setup_revision() == revision else { return }
        let strings = LinuxWindow.Strings()
        let content = LinuxOnboardingPage(step)
        let actions = content.actions.map {
            JSTILinuxSetupAction(title: strings.add(content.title(for: $0)), action: strings.add($0.rawValue))
        }
        var page = JSTILinuxSetupPage(
            step: content.index, has_previous: content.hasPrevious ? 1 : 0, is_last: content.isLast ? 1 : 0,
            title: strings.add(content.title), progress: strings.add(content.progress),
            detail: strings.add(content.detail), status: strings.add(notice ?? message)
        )
        let result = withExtendedLifetime(strings) {
            actions.withUnsafeBufferPointer { jsti_setup_set_page(&page, $0.baseAddress, $0.count, revision) }
        }
        if result != 0 { LinuxHostPlatform.update("The setup page could not be shown. Close and reopen it to retry.") }
    }
}

private func linuxSetupEvent(
    _ revision: UInt64, _ command: Int32, _ step: Int32, _ action: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let action = action.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        guard jsti_setup_revision() == revision else { return }
        await LinuxOnboarding.handle(command, index: step, action: action, revision: revision, holder: holder)
    }
}
