import Foundation

/// Ordered queue row: either an in-flight drop or a materialized movie.
enum JoinQueueEntry: Identifiable, Equatable, Sendable {
    case pending(PendingDropImport)
    case item(JoinQueueItem)

    var id: UUID {
        switch self {
        case .pending(let pending):
            return pending.id
        case .item(let item):
            return item.id
        }
    }

    var asItem: JoinQueueItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    var asPending: PendingDropImport? {
        if case .pending(let pending) = self { return pending }
        return nil
    }
}
