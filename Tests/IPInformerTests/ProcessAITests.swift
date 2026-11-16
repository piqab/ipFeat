import Foundation
import XCTest
@testable import IPInformer

private final class ProcessAIMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class ProcessAITests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProcessAIMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testLocalAndCloudModelRequestsParseTheirOwnResponses() async throws {
        let cases: [(ProcessAIProvider, String, String, String?, String)] = [
            (.openAICompatible, "https://example.com/v1/chat/completions",
             #"{"choices":[{"message":{"content":"A command-line HTTP client."}}]}"#,
             "secret", "A command-line HTTP client."),
            (.ollama, "http://127.0.0.1:11434/api/chat",
             #"{"message":{"content":"A local command-line HTTP client."}}"#,
             nil, "A local command-line HTTP client."),
            (.anthropic, "https://api.anthropic.com/v1/messages",
             #"{"content":[{"type":"text","text":"A network utility."}]}"#,
             "secret", "A network utility."),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta",
             #"{"candidates":[{"content":{"parts":[{"text":"A macOS utility."}]}}]}"#,
             "secret", "A macOS utility.")
        ]
        for (provider, endpoint, response, key, expected) in cases {
            let profile = ProcessAIProfile(name: "Test", provider: provider,
                                           endpoint: endpoint, model: "test-model")
            let built = try ProcessAIClient.makeRequest(
                processPath: "/usr/bin/curl", parentPath: "/bin/zsh",
                applicationName: "iTerm2", profile: profile, key: key
            )
            let bodyText = String(decoding: try XCTUnwrap(built.httpBody), as: UTF8.self)
            XCTAssertTrue(bodyText.contains("/usr/bin/curl"))
            XCTAssertTrue(bodyText.contains("/bin/zsh"))
            ProcessAIMockURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                if provider == .gemini {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
                    XCTAssertTrue(request.url!.path.contains(":generateContent"))
                }
                return (200, Data(response.utf8))
            }
            let result = try await ProcessAIClient.explain(
                processPath: "/usr/bin/curl", parentPath: "/bin/zsh",
                applicationName: "iTerm2", profile: profile, apiKey: key,
                session: session()
            )
            XCTAssertEqual(result, expected)
        }
        ProcessAIMockURLProtocol.handler = nil
    }

    func testRemotePlainHTTPIsRejected() {
        XCTAssertThrowsError(try ProcessAIClient.validateEndpoint("http://example.com/v1/chat/completions", key: nil))
        XCTAssertNoThrow(try ProcessAIClient.validateEndpoint("http://localhost:11434/api/chat", key: nil))
    }

    func testDeepSeekBaseURLsAndMismatchedFormat() throws {
        let openAI = ProcessAIProfile(name: "DeepSeek", provider: .openAICompatible,
                                      endpoint: "https://api.deepseek.com", model: "deepseek-flash")
        let openAIRequest = try ProcessAIClient.makeRequest(
            processPath: "/usr/bin/curl", parentPath: nil, applicationName: nil,
            profile: openAI, key: "test-key"
        )
        XCTAssertEqual(openAIRequest.url?.path, "/chat/completions")

        let anthropic = ProcessAIProfile(name: "DeepSeek", provider: .anthropic,
                                         endpoint: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
        let anthropicRequest = try ProcessAIClient.makeRequest(
            processPath: "/usr/bin/curl", parentPath: nil, applicationName: nil,
            profile: anthropic, key: "test-key"
        )
        XCTAssertEqual(anthropicRequest.url?.path, "/anthropic/v1/messages")

        var mismatched = openAI
        mismatched.endpoint = "https://api.deepseek.com/anthropic"
        XCTAssertThrowsError(try ProcessAIClient.validateProfileEndpoint(mismatched, key: "test-key")) {
            XCTAssertTrue($0.localizedDescription.contains("Anthropic endpoint"))
        }
        mismatched.endpoint = "https://api.deepseek.com/chat/completions"
        mismatched.model = "deepseek-chat"
        XCTAssertThrowsError(try ProcessAIClient.validateProfileEndpoint(mismatched, key: "test-key")) {
            XCTAssertTrue($0.localizedDescription.contains("retired"))
        }
    }
}
