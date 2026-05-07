import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FileExplorerRevealTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    private func makeStore() -> FileExplorerStore {
        let store = FileExplorerStore()
        store.setProvider(LocalFileExplorerProvider())
        store.setRootPath(tempRoot.path)
        return store
    }

    private func waitForRootLoaded(_ store: FileExplorerStore, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.rootNodes.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testRevealsNestedFileInProjectRoot() async throws {
        let sources = tempRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Foo Bar.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let store = makeStore()
        await waitForRootLoaded(store)

        let node = await store.reveal(path: file.path)
        XCTAssertNotNil(node, "reveal should return the node for an existing nested file")
        XCTAssertEqual(node?.path, file.path)
        XCTAssertTrue(store.expandedPaths.contains(sources.path),
                      "ancestor directory must be expanded after reveal")
    }

    func testRevealsDirectoryExpandsIt() async throws {
        let dir = tempRoot.appendingPathComponent("Panels", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = makeStore()
        await waitForRootLoaded(store)

        let node = await store.reveal(path: dir.path)
        XCTAssertNotNil(node)
        XCTAssertTrue(node?.isDirectory ?? false)
        XCTAssertTrue(store.expandedPaths.contains(dir.path))
    }

    func testRevealIgnoresPathOutsideRoot() async throws {
        let store = makeStore()
        await waitForRootLoaded(store)

        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-reveal-other-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("foo.txt")
        let node = await store.reveal(path: outside.path)
        XCTAssertNil(node, "reveal must not locate files outside the configured rootPath")
    }

    func testRevealIgnoresMissingFile() async throws {
        let store = makeStore()
        await waitForRootLoaded(store)

        let missing = tempRoot.appendingPathComponent("does-not-exist.swift")
        let node = await store.reveal(path: missing.path)
        XCTAssertNil(node)
    }

    func testRevealIgnoresEmptyRootPath() async throws {
        let store = FileExplorerStore()
        store.setProvider(LocalFileExplorerProvider())
        let node = await store.reveal(path: tempRoot.appendingPathComponent("foo").path)
        XCTAssertNil(node)
    }

    func testRegistryPicksStoreWhoseRootContainsPath() async throws {
        let sub = tempRoot.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let outerStore = makeStore()
        let innerStore = FileExplorerStore()
        innerStore.setProvider(LocalFileExplorerProvider())
        innerStore.setRootPath(sub.path)
        await waitForRootLoaded(outerStore)

        let file = sub.appendingPathComponent("deep.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let match = FileExplorerStoreRegistry.shared.storeContaining(path: file.path)
        XCTAssertTrue(match === innerStore,
                      "registry must prefer the deepest (most specific) matching root")

        let outsidePath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("definitely-elsewhere-\(UUID().uuidString)").path
        XCTAssertNil(FileExplorerStoreRegistry.shared.storeContaining(path: outsidePath))
    }
}
