import Foundation
import Observation
import StoreKit
import VIGBTCore

/// StoreKit 2 lifetime unlock (Section 2.1). Entitlements are verified on-device: StoreKit checks
/// each transaction's JWS signature and we only trust `.verified` results. No receipt server.
@MainActor
@Observable
final class StoreService {
    /// True only in the field-test build that CI packages for sideloading (`VIGBT_FIELD_TEST`, see
    /// docs/device-testing.md). That build has Pro unlocked because local StoreKit testing only works when
    /// the app is run from Xcode. App Store and Xcode builds never set the flag.
    #if VIGBT_FIELD_TEST
    static let isFieldTestBuild = true
    #else
    static let isFieldTestBuild = false
    #endif

    private(set) var tier: EntitlementTier = StoreService.isFieldTestBuild ? .pro : .free
    private(set) var product: Product?
    private(set) var isPurchasing = false
    private(set) var lastError: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task { await load() }
    }

    func load() async {
        do {
            product = try await Product.products(for: [ProductID.proLifetimeUnlock]).first
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == ProductID.proLifetimeUnlock, t.revocationDate == nil {
                pro = true
            }
        }
        tier = pro || Self.isFieldTestBuild ? .pro : .free
    }

    func purchase() async {
        guard let product else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    await refreshEntitlements()
                } else {
                    lastError = "The purchase could not be verified."
                }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }
}
