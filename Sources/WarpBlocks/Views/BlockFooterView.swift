import SwiftUI

struct BlockFooterView: View {
    let block: Block
    @ObservedObject var session: BlockSessionManager

    var body: some View {
        HStack {
            Spacer()
            if let credits = block.creditsUsed {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "warpblocks.footer.credits", defaultValue: "Credits: %lld"),
                        Int64(credits)
                    )
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
