import Foundation

/// `BombCAD serve`, `BombCAD pair` and `BombCAD nearby`: sharing this Mac's GPU with Macs nearby,
/// pairing with one that shares, and listing them (see `NearbyWorkers`), without the app.
@MainActor
enum HeadlessNearby {
    static let usage = """
        Usage: BombCAD serve [--name <name>] [--store <file>]
               BombCAD pair [<name>] [--code <code>] [--store <file>]
               BombCAD nearby [--store <file>]

        serve shares this Mac's GPU with Macs on the local network until stopped: it advertises
        itself by Bonjour, runs each paired Mac's sessions in a worker of its own, and asks on
        standard input whether a Mac asking to pair may (y to allow), showing the code both Macs
        show. pair pairs with a Mac that serves, named or the only one found: it shows the code,
        which that Mac must show too, and asks for y, or takes --code as the code that Mac shows.
        A paired Mac is then named nearby:<its name> wherever an SSH host is taken, as
        BombCAD watch --on nearby:<name> or BombCAD sweep --worker nearby:<name>. nearby lists the
        Macs serving on the network and those paired. Pairings are kept in the Keychain, or with
        --store (or BOMBCAD_NEARBY_STORE) in a file only its owner can read, as for a Mac worked
        over SSH, whose Keychain may be locked.
        """

    static func main(_ command: String, _ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        var values: [String: String] = [:]
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                guard index + 1 < arguments.count, ["name", "store", "code"].contains(argument.dropFirst(2))
                else {
                    FileHandle.standardError.write(Data("Unknown option \(argument).\n\n\(usage)\n".utf8))
                    return 2
                }
                values[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                positional.append(argument)
                index += 1
            }
        }
        do {
            if let path = values["store"] {
                NearbyWorkers.store = try FilePairingStore(url: URL(filePath: path))
            }
            switch command {
            case "serve": return try await serve(name: values["name"])
            case "pair": return try await pair(positional.first, code: values["code"])
            default: return try await list()
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    nonisolated private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// A line typed on standard input, or nil once it closes; read off the main thread.
    nonisolated private static func readLine() async -> String? {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: Swift.readLine()) }.start()
        }
    }

    private static func serve(name: String?) async throws -> Int32 {
        let store = NearbyWorkers.store
        let server = NearbyServer(store: store, name: name) { peer, code in
            say("\(peer.name) asks to pair; its code is \(code). Allow? [y/N]")
            let answer = await readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            return answer == "y" || answer == "yes"
        }
        server.log = say
        try server.start()
        let paired = store.pairings().map(\.peer.name)
        say(
            "Sharing \(name ?? store.me.name)'s GPU with Macs nearby"
                + (paired.isEmpty ? "; none paired yet." : ", paired with \(paired.joined(separator: ", ")).")
        )
        // Until stopped.
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    private static func pair(_ name: String?, code given: String?) async throws -> Int32 {
        let found = try await discover()
        let candidates = name.map { name in found.filter { $0.name == name } } ?? found
        guard candidates.count == 1, let target = candidates.first else {
            throw NearbyError.refused(
                candidates.isEmpty
                    ? "No Mac\(name.map { " named \($0)" } ?? "") is sharing its GPU nearby."
                    : "Name one of: \(candidates.map(\.name).joined(separator: ", ")).")
        }
        let pairing = try await NearbyWorkers.pair(with: target.advert.id) { peer, code in
            if let given { return given.filter(\.isNumber) == code }
            say("\(peer.name) should now show the code \(code). Does it? [y/N]")
            let answer = await readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            return answer == "y" || answer == "yes"
        }
        print("Paired with \(pairing.peer.name): use it as \(NearbyWorkers.host(pairing.peer.name)).")
        return 0
    }

    private static func list() async throws -> Int32 {
        let found = try await discover()
        let paired = Set(NearbyWorkers.store.pairings().map(\.peer.id))
        if found.isEmpty { print("No Mac is sharing its GPU nearby.") }
        for mac in found {
            let links = mac.interfaces.sorted { NearbyWorkers.rank($0) < NearbyWorkers.rank($1) }
                .map(NearbyWorkers.linkName)
            print(
                "\(mac.name): \(mac.advert.device), BombCAD \(mac.advert.version)"
                    + (mac.advert.compatible ? "" : " (cannot take work from this version)")
                    + ", over \(links.joined(separator: ", "))"
                    + (paired.contains(mac.advert.id)
                        ? ", paired as \(NearbyWorkers.host(mac.name))" : ", not paired"))
        }
        for pairing in NearbyWorkers.store.pairings()
        where !found.contains(where: { $0.advert.id == pairing.peer.id }) {
            print("\(pairing.peer.name): paired, not seen now")
        }
        return 0
    }

    /// The Macs found sharing within a few seconds.
    private static func discover() async throws -> [NearbyBrowser.Found] {
        let browser = NearbyBrowser()
        browser.start()
        defer { browser.stop() }
        try await Task.sleep(for: .seconds(3))
        return browser.found
    }
}
