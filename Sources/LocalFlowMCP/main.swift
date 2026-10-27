import Foundation
import LocalFlowCore

/// The archive as an MCP server over stdio: one JSON-RPC message per line in, one out.
///
/// Thin on purpose — everything worth testing is in `ArchiveMCP`. The store is opened read-only,
/// so this can run while the application is using the same database, and so that a mistake here
/// cannot cost the owner a recording.
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.1"
let store: Store
do {
    store = try Store(readOnly: true)
} catch {
    FileHandle.standardError.write(Data("Архив не открылся: \(error.localizedDescription)\n".utf8))
    exit(1)
}
let server = ArchiveMCP(archive: StoreArchive(store: store), version: version)
let output = FileHandle.standardOutput

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let answer = server.respond(to: line) else { continue }
    output.write(Data((answer + "\n").utf8))
}
