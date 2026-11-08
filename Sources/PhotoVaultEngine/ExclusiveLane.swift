import Foundation

/// One lane for everything that changes jobs, folders or destination state: the sync cycle and
/// the owner's commands never run at the same time (NFR-01). A command that arrives while the
/// cycle works waits until the cycle reaches its next pass boundary (`yieldToCommands`) or an
/// upload loop sees `hasWaitingCommands` and stops starting jobs; the cycle then resumes.
actor ExclusiveLane {
    private enum Holder { case none, cycle, command }

    private var holder = Holder.none
    private var commands: [CheckedContinuation<Void, Never>] = []
    private var cycle: CheckedContinuation<Void, Never>?

    /// True while a command waits for the cycle: the cycle must stop starting new work.
    var hasWaitingCommands: Bool { !commands.isEmpty }

    // MARK: Cycle side

    func beginCycle() async {
        if holder == .none {
            holder = .cycle
            return
        }
        await withCheckedContinuation { cycle = $0 }
    }

    func endCycle() {
        holder = .none
        grant()
    }

    /// Pass boundary: queued commands run now, the cycle continues after the last of them.
    func yieldToCommands() async {
        guard holder == .cycle, !commands.isEmpty else { return }
        holder = .none
        await withCheckedContinuation { continuation in
            cycle = continuation
            grant()
        }
    }

    // MARK: Command side

    func beginCommand() async {
        if holder == .none {
            holder = .command
            return
        }
        await withCheckedContinuation { commands.append($0) }
    }

    func endCommand() {
        holder = .none
        grant()
    }

    /// Commands go first; the cycle takes the lane when none is waiting.
    private func grant() {
        guard holder == .none else { return }
        if !commands.isEmpty {
            holder = .command
            commands.removeFirst().resume()
        } else if let waiting = cycle {
            cycle = nil
            holder = .cycle
            waiting.resume()
        }
    }
}
