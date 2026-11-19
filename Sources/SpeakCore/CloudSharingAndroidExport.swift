import Foundation

/// `CloudSharingConsent` (issue #1805): the providers that need consent,
/// the data kinds and the sheet's copy, so Android asks the same thing.
struct CloudSharingAndroidExport: Encodable {
    struct Kind: Encodable {
        let id, title, purpose: String
    }
    struct SharingProvider: Encodable {
        let id, displayName: String
        let privacyPolicyURL: String?
    }
    /// The Android preference key; the stored JSON matches the Apple store's.
    let storageKey: String
    let kinds: [Kind]
    let providers: [SharingProvider]
    let sheetTitle, allowTitle, useOnDeviceTitle, notNowTitle: String
    let sheetIntroTemplate, singleServiceName, pluralServiceName, blockedMessageTemplate: String
    let withdrawalTitle, withdrawalFooter, emptyWithdrawalText: String

    static let current = CloudSharingAndroidExport(
        storageKey: CloudSharingConsentStore.defaultsKey,
        kinds: CloudSharedDataKind.allCases.map { Kind(id: $0.rawValue, title: $0.title, purpose: $0.purpose) },
        providers: CloudSharingProviderCatalogue.all.map {
            SharingProvider(
                id: $0.id, displayName: $0.displayName, privacyPolicyURL: $0.privacyPolicyURL?.absoluteString
            )
        },
        sheetTitle: CloudSharingConsent.sheetTitle,
        allowTitle: CloudSharingConsent.allowTitle,
        useOnDeviceTitle: CloudSharingConsent.useOnDeviceTitle,
        notNowTitle: CloudSharingConsent.notNowTitle,
        sheetIntroTemplate: CloudSharingConsent.sheetIntroTemplate,
        singleServiceName: CloudSharingConsent.singleServiceName,
        pluralServiceName: CloudSharingConsent.pluralServiceName,
        blockedMessageTemplate: CloudSharingConsent.blockedMessageTemplate,
        withdrawalTitle: CloudSharingConsent.withdrawalTitle,
        withdrawalFooter: CloudSharingConsent.withdrawalFooter,
        emptyWithdrawalText: CloudSharingConsent.emptyWithdrawalText
    )
}
