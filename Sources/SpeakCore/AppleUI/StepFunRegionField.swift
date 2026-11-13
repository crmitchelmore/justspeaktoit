import SwiftUI

public struct StepFunRegionField: View {
    @AppStorage(StepFunCredential.newKeyRegionDefaultsKey)
    private var region = StepFunCredential.Region.defaultForNewKeys.rawValue

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("StepFun key region", selection: $region) {
                ForEach(StepFunCredential.Region.allCases, id: \.rawValue) { value in
                    Text(value.displayName).tag(value.rawValue)
                }
            }
            .accessibilityIdentifier("stepfun-key-region")
            Text("For the new or replacement StepFun key you save below. Keys from platform.stepfun.ai only work "
                + "internationally and keys from platform.stepfun.com only work in China, so choose the site that "
                + "issued the key. The region is saved and transferred with the key; changing it does not change "
                + "an existing key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
