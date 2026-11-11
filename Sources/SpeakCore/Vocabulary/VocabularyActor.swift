#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
public typealias VocabularyActor = MainActor
#else
/// Native desktop loops own the main thread, so vocabulary work uses the cooperative executor.
@globalActor
public actor VocabularyActor {
    public static let shared = VocabularyActor()
}
#endif
