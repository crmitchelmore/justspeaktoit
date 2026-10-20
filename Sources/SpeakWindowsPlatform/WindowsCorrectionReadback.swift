import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

public final class WindowsCorrectionReadback: DesktopCorrectionReadback, @unchecked Sendable {
    private let target: WindowsInsertionTarget
    private let lock = NSLock()
    private var sourceApplication: String?
    public var application: String? { self.lock.withLock { self.sourceApplication } }

    public init(target: WindowsInsertionTarget) { self.target = target }
    public func cancel() { self.target.cancel() }

    public func begin(original: String) throws {
        var error = [CChar](repeating: 0, count: 1_024)
        let result = original.withCString {
            jsti_insertion_learning(self.target.handle, $0, nil, 0, &error, error.count)
        }
        guard result == 0 else { throw WindowsTextOutputError(String(cString: error)) }
        let application = self.target.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.lock.withLock { self.sourceApplication = application }
    }

    public func read() throws -> String {
        var error = [CChar](repeating: 0, count: 1_024)
        var text = [CChar](repeating: 0, count: AutoCorrectionLearningPolicy.maximumUTF16Units * 4 + 1)
        let result = jsti_insertion_learning(self.target.handle, nil, &text, text.count, &error, error.count)
        guard result == 0 else { throw WindowsTextOutputError(String(cString: error)) }
        return String(cString: text)
    }
}
