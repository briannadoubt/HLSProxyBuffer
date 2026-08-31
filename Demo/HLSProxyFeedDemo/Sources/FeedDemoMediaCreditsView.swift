import SwiftUI

struct FeedDemoMediaCreditsView: View {
    let sources: [FeedDemoMediaLibrary.Source]
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Real footage and animation with their original synchronized sound. Excerpts are trimmed, resized and encoded as HLS for this local demo.", bundle: #bundle)
                    ForEach(sources, id: \.id) { source in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: source.title).font(.headline)
                            Text(verbatim: source.credit)
                            Text(verbatim: source.rightsNotes).font(.footnote)
                            Link(destination: source.rightsURL) {
                                Text("Source and reuse information", bundle: #bundle)
                            }
                            Link(destination: source.licenseURL) {
                                Text(verbatim: source.license)
                            }
                        }
                    }
                    Text("NASA does not endorse this demo. Reuse outside the demo must respect the source terms and third-party rights. Live mode simulates a moving window over prerecorded footage.", bundle: #bundle)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(Text("Media credits", bundle: #bundle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onClose) { Text("Done", bundle: #bundle) }
                        .accessibilityIdentifier("media-credits-close")
                }
            }
            .accessibilityIdentifier("media-credits")
        }
    }
}
