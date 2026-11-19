import XCTest

@testable import SpeakApp

#if !APP_STORE
@MainActor
final class LocalPythonSidecarTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPythonSidecarTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSidecar(script: String = "print('hi')\n") -> LocalPythonSidecar {
        LocalPythonSidecar(
            virtualEnvironmentURL: root.appendingPathComponent("venv", isDirectory: true),
            scriptURL: root.appendingPathComponent("runtime/sidecar.py"),
            script: script,
            pythonUnavailable: { URLError(.fileDoesNotExist) }
        )
    }

    func testCurrentScriptURL_writesScriptAndCreatesDirectory() throws {
        let sidecar = makeSidecar()
        let url = try sidecar.currentScriptURL()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "print('hi')\n")
    }

    func testWriteScriptIfNeeded_replacesStaleScript() throws {
        try makeSidecar(script: "old\n").writeScriptIfNeeded()
        let url = try makeSidecar(script: "new\n").currentScriptURL()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new\n")
    }

    func testPythonExecutable_prefersExecutableVirtualEnvironmentInterpreter() throws {
        let sidecar = makeSidecar()
        let python = sidecar.venvPythonURL
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: python.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]
        )
        XCTAssertTrue(sidecar.hasVirtualEnvironment)
        XCTAssertEqual(try sidecar.pythonExecutable(), python)
    }

    func testPrepareVirtualEnvironment_skipsVenvCreationWhenPresent() async throws {
        let sidecar = makeSidecar()
        try FileManager.default.createDirectory(
            at: sidecar.venvPythonURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: sidecar.venvPythonURL.path, contents: Data())
        let hasSystemPython = LocalPythonSidecar.bootstrapCandidates
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(hasSystemPython, "Needs a system python3 to bootstrap")
        var created = false
        let python = try await sidecar.prepareVirtualEnvironment { _, _ in created = true }
        XCTAssertFalse(created)
        XCTAssertEqual(python, sidecar.venvPythonURL)
    }

    func testHuggingFaceURL_percentEncodesEachPathSegment() {
        let url = HuggingFaceFileDownload.url(repoID: "org/model", filename: "dir/file name.gguf")
        XCTAssertEqual(
            url?.absoluteString,
            "https://huggingface.co/org/model/resolve/main/dir/file%20name.gguf?download=true"
        )
    }
}
#endif
