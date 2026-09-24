import Foundation

@MainActor
enum PendingSaveRegistry {
    private static var handlers: [UUID: @MainActor () async -> Bool] = [:]

    static var isEmpty: Bool { handlers.isEmpty }

    static func register(id: UUID, flush: @escaping @MainActor () async -> Bool) {
        handlers[id] = flush
    }

    static func unregister(id: UUID) {
        handlers[id] = nil
    }

    static func flushAll() async -> Bool {
        let currentHandlers = Array(handlers.values)
        for flush in currentHandlers {
            guard await flush() else { return false }
        }
        return true
    }
}
