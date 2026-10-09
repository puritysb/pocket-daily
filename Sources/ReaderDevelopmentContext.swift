#if DEBUG
/// Lets explicitly opted-in hardware tests drive the app's real model and radio
/// ownership. No listener, alternate transport, or shipping control interface.
@MainActor
enum ReaderDevelopmentContext {
    static weak var model: PocketModel?
}
#endif
