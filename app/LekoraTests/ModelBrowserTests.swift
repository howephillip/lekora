import XCTest
@testable import Lekora

/// Prices, OpenRouter's catalog, hosts and routing (docs/model-picker.md).
@MainActor
final class ModelBrowserTests: XCTestCase {
    func testPriceAndContextWording() {
        XCTAssertEqual(LKModelText.price(3), "$3.00")
        XCTAssertEqual(LKModelText.price(15), "$15")
        XCTAssertEqual(LKModelText.price(0.038), "$0.038")
        XCTAssertEqual(LKModelText.price(0), "Free")
        XCTAssertNil(LKModelText.price(nil))
        XCTAssertEqual(LKModelText.prices(input: 0.08, output: 0.5), "$0.08 in · $0.50 out")
        XCTAssertEqual(LKModelText.prices(input: 0, output: 0), "Free")
        XCTAssertNil(LKModelText.prices(input: nil, output: 1))
        XCTAssertEqual(LKModelText.context(1_048_576), "1M")
        XCTAssertEqual(LKModelText.context(131_072), "131K")
        XCTAssertEqual(LKModelText.context(2_500_000), "2.5M")
        XCTAssertNil(LKModelText.context(0))
        XCTAssertEqual(LKModelText.price(0.05), "$0.05")
        XCTAssertEqual(LKModelText.price(0.1), "$0.10")
        XCTAssertEqual(LKModelText.price(0.006), "$0.006")
    }

    func testHostVariantsTellSameNamedHostsApart() {
        func host(_ tag: String, _ quant: String?) -> ModelHost {
            ModelHost(name: "X", tag: tag, input: nil, output: nil, cache_read: nil, discount: nil, context: nil,
                      max_output: nil, quantization: quant, uptime: nil)
        }
        XCTAssertEqual(LKModelDetail.variant(of: host("wafer/us", "mxfp4")), ["US", "MXFP4"])
        XCTAssertEqual(LKModelDetail.variant(of: host("deepinfra/fp8/flex", "fp8")), ["FP8", "FLEX"])
        XCTAssertEqual(LKModelDetail.variant(of: host("together", nil)), [])
        var us = host("wafer/us", "mxfp4")
        us.country = "US"
        XCTAssertEqual(LKModelDetail.variant(of: us), ["MXFP4"], "the flag already says US")
        XCTAssertEqual(LKModelDetail.flag("US"), "🇺🇸")
        XCTAssertEqual(LKModelDetail.flag("sg"), "🇸🇬")
        XCTAssertNil(LKModelDetail.flag("EU-WEST"))
    }

    private let models = [
        CatalogModel(id: "deepseek/v4", name: "DeepSeek V4", maker: "deepseek", maker_name: "DeepSeek", created: 3,
                     context: 1_048_576, input: 0.08, output: 0.5, free: false, reasoning: true, vision: true),
        CatalogModel(id: "deepseek/v3", name: "DeepSeek V3", maker: "deepseek", maker_name: "DeepSeek", created: 1,
                     context: 64_000, input: 0.2, output: 0.8, free: false, reasoning: false),
        CatalogModel(id: "meta/llama:free", name: "Llama", maker: "meta", maker_name: "Meta", created: 2,
                     context: 131_072, input: 0, output: 0, free: true),
    ]

    func testFilteringAndSorting() {
        XCTAssertEqual(LKOpenRouterBrowser.filter(models, search: "", freeOnly: true).map(\.id), ["meta/llama:free"])
        XCTAssertEqual(LKOpenRouterBrowser.filter(models, search: "meta", freeOnly: false).map(\.id), ["meta/llama:free"])
        XCTAssertEqual(LKOpenRouterBrowser.filter(models, search: "deepseek v4", freeOnly: false).map(\.id), ["deepseek/v4"],
                       "every word, anywhere in the name or id")
        XCTAssertTrue(LKModelText.matches("v4.1 flash", in: ["deepseek/deepseek-v4.1-flash-1017", nil]))
        XCTAssertEqual(LKOpenRouterBrowser.filter(models, search: "", freeOnly: false, reasoningOnly: true).map(\.id), ["deepseek/v4"])
        XCTAssertEqual(LKOpenRouterBrowser.sorted(models, by: .cheapest).map(\.id), ["meta/llama:free", "deepseek/v4", "deepseek/v3"])
        XCTAssertEqual(LKOpenRouterBrowser.sorted(models, by: .newest).map(\.id), ["deepseek/v4", "meta/llama:free", "deepseek/v3"])
        XCTAssertEqual(LKOpenRouterBrowser.sorted(models, by: .context).first?.id, "deepseek/v4")
        let groups = LKOpenRouterBrowser.byMaker(models)
        XCTAssertEqual(groups.map(\.name), ["DeepSeek", "Meta"], "most models first")
    }

    func testCatalogHostsAndRoutingFromTheHost() async throws {
        let host = try FakeHost()
        try await host.start()
        defer { host.stop() }
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["assistant"], activeProfileId: "assistant").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        await gateway.resumeSavedSession()

        let catalog = try await gateway.modelCatalog(provider: "openrouter", in: "assistant")
        XCTAssertEqual(catalog.models.count, 2)
        XCTAssertEqual(catalog.models.first?.input, 0.08)
        XCTAssertEqual(catalog.models.last?.free, true)

        let hosts = try await gateway.modelHosts("deepseek/v4", in: "assistant")
        XCTAssertEqual(hosts.hosts.first?.quantization, "mxfp4")
        XCTAssertEqual(hosts.routing.mode, "balanced")

        let saved = try await gateway.setRouting("deepseek/v4", mode: "only", hosts: ["wafer/us"], noTraining: true, in: "assistant")
        XCTAssertEqual(saved.mode, "only")
        XCTAssertEqual(saved.hosts, ["wafer/us"])
        XCTAssertNotNil(saved.backup)
        let sent = host.received(type: "models.routing.set").last?["data"] as? [String: Any]
        XCTAssertEqual(sent?["model"] as? String, "deepseek/v4")
        XCTAssertEqual(sent?["hosts"] as? [String], ["wafer/us"])
        XCTAssertEqual(sent?["no_training"] as? Bool, true)
    }
}
