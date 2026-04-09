import SwiftUI
import UIKit

/// Shown when a seed photo contains multiple faces. The user taps the correct person.
struct FacePickerView: View {
    let crops: [(crop: UIImage, normalizedBox: CGRect)]
    let onSelect: (UIImage) -> Void
    let onSkip: () -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Which person is your friend?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(crops.indices, id: \.self) { i in
                        Button {
                            onSelect(crops[i].crop)
                        } label: {
                            Image(uiImage: crops[i].crop)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .shadow(radius: 4)
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                Button("None of these") { onSkip() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 32)
            }
            .navigationTitle("Pick Your Friend")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
