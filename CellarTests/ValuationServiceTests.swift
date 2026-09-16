import XCTest
@testable import Cellar

final class ValuationServiceTests: XCTestCase {

    func testDecodesEndpointContract() throws {
        let json = """
        {
          "average": 189.00,
          "min": 165.00,
          "max": 220.00,
          "currency": "USD",
          "score": 95,
          "source": "vivino",
          "offers": [
            { "merchant": "Wine Library", "price": 175.00, "currency": "USD",
              "url": "https://example.com/x", "address": "123 Main St",
              "latitude": 41.03, "longitude": -73.76, "inStock": true },
            { "merchant": "Total Wine", "price": 182.50 }
          ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(RemoteValuationDTO.self, from: json)
        XCTAssertEqual(dto.average, Decimal(string: "189.00"))
        XCTAssertEqual(dto.currency, "USD")
        XCTAssertEqual(dto.score, 95)
        XCTAssertEqual(dto.source, "vivino")
        XCTAssertEqual(dto.offers?.count, 2)
        XCTAssertEqual(dto.offers?.first?.merchant, "Wine Library")
        XCTAssertEqual(dto.offers?.first?.latitude, 41.03)
        // Sparse offer: missing optionals decode as nil, not a failure.
        XCTAssertNil(dto.offers?.last?.url)
        XCTAssertNil(dto.offers?.last?.inStock)
    }

    func testDecodesEmptyOffers() throws {
        let json = #"{ "average": 50.0, "currency": "USD" }"#.data(using: .utf8)!
        let dto = try JSONDecoder().decode(RemoteValuationDTO.self, from: json)
        XCTAssertEqual(dto.average, Decimal(50))
        XCTAssertNil(dto.offers)
        // An older proxy omits the source; the client falls back to its own tag.
        XCTAssertNil(dto.source)
    }

    func testUnconfiguredEndpointIsNotConfigured() {
        // No baseURL → not configured (empty UserDefaults in the test host).
        let cfg = ValuationConfig(baseURL: nil, apiKey: nil)
        XCTAssertFalse(cfg.isConfigured)
    }

    func testRemoteHTTPEndpointIsRejected() {
        let cfg = ValuationConfig(baseURL: URL(string: "http://insecure.example.com"), apiKey: nil)
        XCTAssertFalse(cfg.isConfigured)   // remote http must be HTTPS
    }

    func testLocalhostHTTPEndpointIsAllowed() {
        // Plain http is permitted only for a local dev proxy.
        XCTAssertTrue(ValuationConfig(baseURL: URL(string: "http://127.0.0.1:8787"), apiKey: nil).isConfigured)
        XCTAssertTrue(ValuationConfig(baseURL: URL(string: "http://localhost:8787"), apiKey: nil).isConfigured)
    }

    func testLANHTTPEndpointIsAllowed() {
        // A physical iPhone reaches the dev proxy on the Mac over Wi-Fi.
        XCTAssertTrue(ValuationConfig(baseURL: URL(string: "http://192.168.68.114:8787"), apiKey: nil).isConfigured)
        XCTAssertTrue(ValuationConfig(baseURL: URL(string: "http://10.0.0.5:8787"), apiKey: nil).isConfigured)
        XCTAssertTrue(ValuationConfig(baseURL: URL(string: "http://172.20.1.2:8787"), apiKey: nil).isConfigured)
        XCTAssertTrue(ValuationConfig(baseURL: URL(string: "http://my-mac.local:8787"), apiKey: nil).isConfigured)
    }

    func testPublicIPHTTPEndpointIsRejected() {
        XCTAssertFalse(ValuationConfig(baseURL: URL(string: "http://8.8.8.8:8787"), apiKey: nil).isConfigured)
        XCTAssertFalse(ValuationConfig(baseURL: URL(string: "http://172.32.0.1"), apiKey: nil).isConfigured)
        XCTAssertFalse(ValuationConfig(baseURL: URL(string: "http://192.168.1.300"), apiKey: nil).isConfigured)
    }

    func testHTTPSEndpointIsConfigured() {
        let cfg = ValuationConfig(baseURL: URL(string: "https://host.example.com/api"), apiKey: "k")
        XCTAssertTrue(cfg.isConfigured)
    }
}
