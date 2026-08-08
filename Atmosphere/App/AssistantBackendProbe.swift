#if DEBUG
import Foundation

/// Runs one real turn against a backend and prints what came back.
///
/// Debug-only: `--probe-claude "<prompt>"`. The process plumbing — spawning the
/// CLI, streaming input, framing, event mapping — cannot be exercised by a unit
/// test, so this exists to check it against the real thing.
@MainActor
enum AssistantBackendProbe {
    static let argument = "--probe-claude"

    static func promptFromArguments() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run(prompt: String) {
        Task {
            let client = ClaudeCodeClient()
            var deltaCount = 0
            var text = ""

            let listener = Task {
                for await event in client.events {
                    switch event {
                    case .connectionStateChanged(let state):
                        print("connection: \(state)")
                    case .threadReady(let threadID):
                        print("thread ready: \(threadID)")
                    case .turnStarted(_, let turnID):
                        print("turn started: \(turnID)")
                    case .assistantMessageStarted:
                        print("message started")
                    case .assistantDelta(_, _, _, let delta):
                        deltaCount += 1
                        text += delta
                    case .assistantMessageCompleted(_, _, _, let final, _):
                        text = final
                        print("message completed (\(deltaCount) deltas)")
                    case .turnCompleted(_, _, let status, let failure):
                        print("turn \(status.rawValue)\(failure.map { ": \($0.message)" } ?? "")")
                        print("--- answer ---")
                        print(text)
                        print("--------------")
                        exit(failure == nil && !text.isEmpty ? 0 : 1)
                    default:
                        break
                    }
                }
            }

            let activityListener = Task {
                for await activity in client.activityEvents {
                    print("activity: \(activity.kind.rawValue) — \(activity.message)")
                }
            }

            do {
                _ = try await client.start()
                _ = try await client.send(prompt, localImages: [])
            } catch {
                print("probe failed: \(error.localizedDescription)")
                exit(1)
            }

            try? await Task.sleep(nanoseconds: 120_000_000_000)
            listener.cancel()
            activityListener.cancel()
            print("probe timed out")
            exit(1)
        }
    }
}
#endif
