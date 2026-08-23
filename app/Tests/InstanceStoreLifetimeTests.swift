import XCTest
@testable import DoppelMenuBar

/// The store schedules a delayed update check and two repeating timers in
/// init. None of them stop on their own when the store goes away, so deinit
/// has to close them out.
final class InstanceStoreLifetimeTests: XCTestCase {
    @MainActor
    func testDeinitCancelsTheDelayedUpdateCheck() {
        var launchWork: Task<Void, Never>?
        do {
            let store = InstanceStore()
            launchWork = store.firstUpdateCheck
            XCTAssertNotNil(launchWork, "init should hold on to the delayed check")
            XCTAssertEqual(launchWork?.isCancelled, false,
                           "the check should still be pending while the store is alive")
        }
        XCTAssertEqual(launchWork?.isCancelled, true,
                       "deinit must cancel the delayed check; it sleeps for twelve seconds "
                       + "and would otherwise outlive the store that scheduled it")
    }

    @MainActor
    func testTheStoreCanActuallyDeallocate() {
        weak var released: InstanceStore?
        do {
            let store = InstanceStore()
            released = store
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released, "a retained store would keep deinit from ever running")
    }
}
