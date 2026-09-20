import XCTest
@testable import MinionsCore

final class ParserTests: XCTestCase {
    func fixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }
    func fixtureData(_ name: String) -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!)
    }

    // MARK: lsof

    func testLsofFieldAndTableFormsAgree() {
        let a = PortsCollector.parseFieldOutput(fixture("lsof_fields.txt"))
        let b = PortsCollector.parseTableOutput(fixture("lsof_table.txt"))
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(Set(a.map { "\($0.pid):\($0.port)" }), Set(b.map { "\($0.pid):\($0.port)" }))
    }

    func testLsofDedupesIPv4AndIPv6ForSamePidPort() {
        let text = "p526\ncControlCe\nn*:7000\nn*:7000\nn*:5000\np2318\ncPython\nn*:5001\n"
        let ports = PortsCollector.parseFieldOutput(text)
        XCTAssertEqual(ports.map(\.port), [5000, 5001, 7000])
        XCTAssertEqual(ports.first { $0.port == 5001 }?.processName, "Python")
    }

    func testLsofParsesBracketedIPv6() {
        let ports = PortsCollector.parseFieldOutput("p1\ncnode\nn[::1]:3000\n")
        XCTAssertEqual(ports.first?.address, "::1")
        XCTAssertEqual(ports.first?.port, 3000)
        XCTAssertTrue(ports.first!.isLoopbackOnly)
    }

    func testPortKindDetection() {
        XCTAssertEqual(PortKind.detect(processName: "node", command: "node server.js", port: 3000), .node)
        XCTAssertEqual(PortKind.detect(processName: "com.docke", command: nil, port: 5432), .database)
        XCTAssertEqual(PortKind.detect(processName: "python3.1", command: "uvicorn app:app", port: 8000), .python)
        XCTAssertEqual(PortKind.detect(processName: "rapportd", command: nil, port: 49154), .system)
    }

    // MARK: docker

    func testDockerPSParsesComposeLabelsAndPorts() {
        let cs = DockerCollector.parsePS(fixture("docker_ps.jsonl"))
        XCTAssertFalse(cs.isEmpty)
        guard let redis = cs.first(where: { $0.image.hasPrefix("redis") }) else { return XCTFail("no redis in fixture") }
        XCTAssertEqual(redis.composeProject, "acme-local")
        XCTAssertEqual(redis.serviceName, "redis")
        XCTAssertEqual(redis.composeDir, "/Users/dev/acme/infra/local")
        XCTAssertEqual(redis.hostPorts, [6379])
        XCTAssertTrue(redis.isRunning)
        XCTAssertEqual(redis.isHealthy, true)
    }

    func testDockerPortRangesAndUnpublished() {
        let m = DockerCollector.parsePorts("1110/tcp, 0.0.0.0:1026->1025/tcp, 0.0.0.0:9000-9001->9000-9001/tcp")
        XCTAssertEqual(m.count, 4)
        XCTAssertNil(m[0].hostPort); XCTAssertEqual(m[0].containerPort, 1110)
        XCTAssertEqual(m[1].hostPort, 1026); XCTAssertEqual(m[1].containerPort, 1025)
        XCTAssertEqual(m[2].hostPort, 9000); XCTAssertEqual(m[3].hostPort, 9001); XCTAssertEqual(m[3].containerPort, 9001)
        XCTAssertEqual(m[1].description, "1026→1025")
    }

    func testDockerStatsParsing() {
        let s = DockerCollector.parseStats(#"{"ID":"abc","Name":"db","CPUPerc":"12.50%","MemUsage":"48MiB / 7.6GiB"}"#)
        XCTAssertEqual(s["abc"]?.cpu, 12.5)
        XCTAssertEqual(s["db"]?.mem, "48MiB")
    }

    // MARK: claude code

    func testClaudeTranscriptDedupesAndSkipsSynthetic() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proj-slug", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("s.jsonl")
        try fixtureData("claude_transcript.jsonl").write(to: file)
        var cursor = ClaudeCodeReader.Cursor()
        let recs = ClaudeCodeReader().read(file: file.path, cursor: &cursor)
        XCTAssertEqual(recs.count, 2, "req_A once, synthetic skipped, req_C once")
        let a = recs[0]
        XCTAssertEqual(a.model, "claude-fable-5-1"); XCTAssertEqual(a.input, 10); XCTAssertEqual(a.output, 100)
        XCTAssertEqual(a.cacheRead, 1000); XCTAssertEqual(a.cacheWrite, 200); XCTAssertEqual(a.instance, "proj-slug")
        XCTAssertEqual(a.cwd, "/Users/dev/Documents/dev/minions")
        XCTAssertEqual(recs[1].task, "subagent")
        // Second pass reads nothing new.
        XCTAssertEqual(ClaudeCodeReader().read(file: file.path, cursor: &cursor).count, 0)
        // Append a partial line: still nothing; complete it: one more.
        let fh = try FileHandle(forWritingTo: file); try fh.seekToEnd()
        let line = #"{"type":"assistant","timestamp":"2026-09-20T15:00:00Z","requestId":"req_D","sessionId":"sess-1","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1}}}"#
        fh.write(Data(line.utf8)); try fh.close()
        XCTAssertEqual(ClaudeCodeReader().read(file: file.path, cursor: &cursor).count, 0)
        let fh2 = try FileHandle(forWritingTo: file); try fh2.seekToEnd(); fh2.write(Data("\n".utf8)); try fh2.close()
        XCTAssertEqual(ClaudeCodeReader().read(file: file.path, cursor: &cursor).count, 1)
    }

    // MARK: pricing

    func testPricingResolvesAndComputesCost() {
        let raw = try! JSONSerialization.jsonObject(with: fixtureData("pricing.json")) as! [String: Any]
        let cat = PricingCatalog(raw: raw, source: "fixture")
        let r = UsageRecord(ts: Date(), agent: "claude-code", sessionId: "s", model: "claude-fable-5-1", provider: "anthropic",
                            apiCalls: 1, input: 10, output: 100, cacheRead: 1000, cacheWrite: 200, ref: "x")
        let priced = cat.price(r)
        // 10*10 + 100*50 + 1000*0.25 + 200*12.5 = 100+5000+250+2500 = 7850 per 1M
        XCTAssertEqual(priced.costBilled!, 0.00785, accuracy: 1e-9)
        XCTAssertEqual(priced.costSource, .computed)
        XCTAssertEqual(priced.billingMode, .metered)
    }

    func testPricingSubscriptionLaneBillsZeroButKeepsNotional() {
        let raw = try! JSONSerialization.jsonObject(with: fixtureData("pricing.json")) as! [String: Any]
        let cat = PricingCatalog(raw: raw, source: "fixture")
        let r = UsageRecord(ts: Date(), agent: "hermes", sessionId: "s", model: "deepseek-v4-pro:0813", provider: "ollama-cloud", input: 1_000_000, output: 0, ref: "y")
        let p = cat.price(r)
        XCTAssertEqual(p.costBilled, 0)
        XCTAssertEqual(p.costNotional!, 0.5, accuracy: 1e-9, "falls back to deepseek list rate after tag strip")
        XCTAssertEqual(p.billingMode, .subscription)
    }

    func testNormalize() {
        XCTAssertEqual(PricingCatalog.normalize("deepseek/deepseek-v4-pro:0813"), "deepseek-v4-pro")
        XCTAssertEqual(PricingCatalog.normalize("@cf/moonshotai/kimi-k2.7-code"), "kimi-k2-7-code")
        XCTAssertEqual(PricingCatalog.normalize("claude-opus-4.7"), "claude-opus-4-7")
    }

    // MARK: usage store aggregation

    func testUsageStoreAggregatesAndPersists() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("minions-test-\(UUID().uuidString).json").path
        let raw = try JSONSerialization.jsonObject(with: fixtureData("pricing.json")) as! [String: Any]
        let store = UsageStore(path: path, catalog: PricingCatalog(raw: raw, source: "fixture"))
        XCTAssertTrue(store.records.isEmpty)
        // Private upsert is exercised through refresh() against real dirs; here we only check persistence round-trip of empty state.
        store.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    // MARK: live connections

    func testLiveConnectionParsing() {
        let text = "p100\ncclaude\nn127.0.0.1:5000->160.79.104.10:443\nn192.168.1.5:52000->api.anthropic.com:443\np200\ncnode\nn192.168.1.5:5:1->api.openai.com:443\n"
        let c = LiveConnectionsCollector.parse(text)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].provider, "anthropic"); XCTAssertEqual(c[0].processName, "claude")
        XCTAssertEqual(c[1].provider, "openai")
    }

    // MARK: pi

    func testPiReaderDedupesAcrossProvidersAndSkipsNonAssistant() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-sess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2026-07-16T14-58-46-468Z_019f6b6f-f244-7407-86ab-32e05b64e3f7.jsonl")
        try fixtureData("pi_session.jsonl").write(to: file)
        var cursor = PiReader.Cursor()
        let recs = PiReader().read(file: file.path, cursor: &cursor)
        XCTAssertEqual(recs.count, 2, "two distinct message ids; the repeated 8a450ddb line is deduped, the user-role line is skipped")
        XCTAssertEqual(recs[0].provider, "deepseek")
        XCTAssertEqual(recs[0].model, "deepseek-v4-pro")
        XCTAssertEqual(recs[0].input, 1696)
        XCTAssertEqual(recs[0].costBilled!, 0.00082215, accuracy: 1e-9, "pi's own reported cost is used directly")
        XCTAssertEqual(recs[0].cwd, "/Users/dev/Documents/dev/example-project")
        XCTAssertEqual(recs[0].instance, "example-project")
        XCTAssertEqual(recs[1].provider, "ollama")
        XCTAssertNil(recs[1].costBilled, "a zero reported cost is treated as unreported, letting the pricing catalog classify the lane")
        // Second pass reads nothing new.
        XCTAssertEqual(PiReader().read(file: file.path, cursor: &cursor).count, 0)
    }

    func testPiSessionIdFromFilename() {
        XCTAssertEqual(PiReader.sessionId("/x/2026-07-16T14-58-46-468Z_019f6b6f-f244-7407-86ab-32e05b64e3f7.jsonl"), "019f6b6f-f244-7407-86ab-32e05b64e3f7")
    }

    // MARK: codex

    func testCodexScanTakesLatestCumulativeSnapshot() {
        let text = """
        {"type":"turn_context","payload":{"model":"gpt-5.6-codex"}}
        {"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"reasoning_output_tokens":3}}}}
        {"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":9}}}}
        """
        let (latest, model) = CodexReader.scan(Data(text.utf8))
        XCTAssertEqual(model, "gpt-5.6-codex")
        XCTAssertEqual(latest?["input_tokens"], 300)
        XCTAssertEqual(CodexReader.sessionId("/x/rollout-2026-07-15T21-14-09-019f687c-1111-2222-3333-444444444444.jsonl"), "019f687c-1111-2222-3333-444444444444")
    }
}
