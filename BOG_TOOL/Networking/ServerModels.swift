import Foundation

/// API path constants matching bog-test-server/main.py.
/// Keep in sync with the FastAPI routes.
enum ServerAPI {
    static let productionTest = "/api/production-test"
    static let summary = "/api/summary"
    static let firmwareUpgradeRecord = "/api/firmware-upgrade-record"
}
