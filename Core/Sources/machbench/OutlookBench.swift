import MachCore
import MachFake
import Foundation

// The same two questions `sync-poll` and `sync-signal` answer for Gmail, for Outlook: what one idle check costs,
// and how long a relay's signal takes to put new mail on screen. Outlook is played by `FakeGraph`, in memory, with
// a fixed delay per round trip, so the numbers are round trips and our own overhead, not Microsoft's weather.
//
//   machbench sync-outlook <empty-dir> [latency-ms=120] [runs=15]

private struct OutlookTokens: TokenStore {
    func load(account: String) -> TokenSet? {
        TokenSet(refreshToken: "none", accessToken: "fake-" + account, expiry: .distantFuture, provider: .microsoft)
    }
    func save(_ tokens: TokenSet, account: String) {}
    func delete(account: String) {}
}

private final class Done: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    func finish(_ value: Result<Void, Error>) { lock.withLock { result = value } }
    var value: Result<Void, Error>? { lock.withLock { result } }
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
private func middle(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
private func high(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, values.count * 9 / 10)] }

/// Requests that start within half a round trip of each other count as one trip.
private func trips(_ calls: [FakeGraph.Call], latency: Double) -> Int {
    var count = 0
    var began = -Double.infinity
    for call in calls.sorted(by: { $0.start < $1.start }) where call.start - began > max(latency / 2, 0.0005) {
        count += 1
        began = call.start
    }
    return count
}

private func quiet(_ server: FakeGraph) async {
    var last = server.calls.count
    var since = now()
    while now() - since < 0.5 {
        await pause(0.02)
        if server.calls.count != last {
            last = server.calls.count
            since = now()
        }
    }
}

private func syncOutlook(_ directory: URL, _ args: [String]) throws {
    let latency = (Double(args.first ?? "") ?? 120) / 1000
    let runs = args.count > 1 ? Int(args[1]) ?? 15 : 15
    let account = "bench@outlook.example"
    let done = Done()
    Task.detached {
        do {
            let server = FakeGraph(email: account, latency: latency)
            server.seed(60, folder: "archive")
            server.seed(40)
            let mail = try MailService(directory: directory, client: OAuthClient(clientId: "bench", clientSecret: nil),
                                       microsoftClient: OAuthClient(clientId: "bench", clientSecret: nil), tokens: OutlookTokens(),
                                       transport: GmailTransport(protocolClasses: [FakeGraphProtocol.self]))
            mail.onReport = { _, message in FileHandle.standardError.write(Data("sync reported: \(message)\n".utf8)) }
            if try mail.store.account(account) == nil { try mail.store.saveAccount(Account(id: account, name: "Bench", provider: .microsoft)) }
            let sync = mail.sync(for: account)
            // The first day: everything is taken in, and the filling-in behind it runs to its end.
            for _ in 0..<5 {
                await sync.sync()
                await quiet(server)
            }

            var time: [Double] = [], requests: [Double] = [], rounds: [Double] = []
            for run in 0..<(runs + 2) {
                server.resetLog()
                let start = now()
                await sync.sync()
                let end = now()
                await quiet(server)
                guard run >= 2 else { continue }
                time.append((end - start) * 1000)
                requests.append(Double(server.calls.count))
                rounds.append(Double(trips(server.calls, latency: latency)))
            }
            report("sync.outlook.poll", ["latency_ms": latency * 1000, "check_median_ms": middle(time), "check_p90_ms": high(time),
                                         "requests": middle(requests), "round_trips": middle(rounds), "runs": Double(time.count)])

            var visible: [Double] = [], returned: [Double] = []
            requests = []
            rounds = []
            for run in 0..<(runs + 2) {
                server.resetLog()
                let id = server.deliver().first!
                let start = now()
                let pass = Task { await sync.sync(newMail: true) }
                var seen: Double?
                while seen == nil, now() - start < 30 {
                    if (try? mail.store.message(account: account, id: id)) != nil { seen = now() }
                    await pause(0.0005)
                }
                await pass.value
                let end = now()
                guard let seen else { throw BenchError("new mail never reached the database") }
                let before = server.calls.filter { $0.start <= seen }
                await quiet(server)
                guard run >= 2 else { continue }
                visible.append((seen - start) * 1000)
                returned.append((end - start) * 1000)
                requests.append(Double(server.calls.count))
                rounds.append(Double(trips(before, latency: latency)))
            }
            report("sync.outlook.signal", ["latency_ms": latency * 1000, "stored_median_ms": middle(visible), "stored_p90_ms": high(visible),
                                           "sync_returned_median_ms": middle(returned), "round_trips_to_stored": middle(rounds),
                                           "requests_whole_pass": middle(requests), "runs": Double(visible.count)])
            server.close()
            done.finish(.success(()))
        } catch {
            done.finish(.failure(error))
        }
    }
    while true {
        if let value = done.value {
            try value.get()
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func registerOutlookBenchmarks(directory: URL) {
    benchmarks["sync-outlook"] = { _, args in try syncOutlook(directory, args) }
}
