import SwiftUI

struct JijiCat: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "cat.fill")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color.primary)
    }
}
