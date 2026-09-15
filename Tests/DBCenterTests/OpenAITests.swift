import AppKit
import XCTest
@testable import DBCenter

final class OpenAITests: XCTestCase {
    private let schema = AISchema(engine: "Postgres", database: "example", objects: [.init(name: "people", schema: "public", columns: ["id", "name"], note: nil)], note: "Names only")

    func testRequestContainsSchemaAndSelectedModelWithoutStoringResponse() throws {
        let request = try OpenAIClient.generationRequest(key: "test-key", model: "chosen-model", prompt: "Find people", schema: schema)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "chosen-model")
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertTrue(input[0]["content"]?.contains("people") == true)
        XCTAssertTrue(input[0]["content"]?.contains("columns") == true)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
    }
    func testResponseSkipsReasoningAndStripsCodeFence() throws {
        let data = Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"```sql\nSELECT 1;\n```"}]}]}"#.utf8)
        XCTAssertEqual(try OpenAIClient.query(from: data), "SELECT 1;")
    }
    func testIncompleteRefusalAndEmptyResponsesDoNotProduceQueries() {
        for json in [
            #"{"status":"incomplete","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SELECT"}]}]}"#,
            #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"Cannot generate."}]}]}"#,
            #"{"status":"completed","output":[]}"#
        ] { XCTAssertThrowsError(try OpenAIClient.query(from: Data(json.utf8))) }
    }
    func testMissingConfigurationAndOversizedSchemaFailBeforeSending() {
        XCTAssertThrowsError(try OpenAIClient.generationRequest(key: "", model: "model", prompt: "find", schema: schema))
        XCTAssertThrowsError(try OpenAIClient.generationRequest(key: "key", model: "", prompt: "find", schema: schema))
        let huge = AISchema(engine: "Postgres", database: "db", objects: [], note: String(repeating: "x", count: 200_001))
        XCTAssertThrowsError(try huge.json())
    }
    @MainActor
    func testGenerationDoesNotOverwriteEditsAndSupportsRestore() async {
        let workspace = Workspace(server: Server())
        workspace.query = "SELECT original;"
        let revision = workspace.queryRevision
        workspace.query = "SELECT edited;"
        workspace.receiveAIQuery("SELECT generated;", originalRevision: revision)
        XCTAssertEqual(workspace.query, "SELECT edited;")
        XCTAssertEqual(workspace.pendingAIQuery, "SELECT generated;")
        workspace.insertAIQuery(workspace.pendingAIQuery!)
        XCTAssertEqual(workspace.query, "SELECT generated;")
        XCTAssertEqual(workspace.querySelection.length, (workspace.query as NSString).length)
        XCTAssertTrue(workspace.history.isEmpty)
        XCTAssertNil(workspace.result)
        workspace.restoreAIDraft()
        XCTAssertEqual(workspace.query, "SELECT edited;")
        workspace.receiveAIQuery("SELECT next;", originalRevision: workspace.queryRevision)
        XCTAssertEqual(workspace.query, "SELECT next;")
    }
    func testHTTPModelListAndAuthenticationError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = OpenAIClient(session: session)
        let models = try await client.models(key: "fixture-key")
        XCTAssertEqual(models, ["model-a", "model-b"])
        do {
            _ = try await client.generate(key: "fixture-key", model: "model-a", prompt: "Find people", schema: schema)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-key"))
        }
    }
}

private final class OpenAIFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let models = request.url!.path.hasSuffix("/models")
        let json = models ? #"{"data":[{"id":"model-b"},{"id":"model-a"}]}"# : #"{"error":{"message":"Invalid key fixture-key"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: models ? 200 : 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
