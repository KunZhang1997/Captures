import SwiftUI

struct GitHubRepositoryLink: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Localization.string("GitHub Open Source"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let repositoryURL = URL(string: Constants.App.githubURL) {
                Link(destination: repositoryURL) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: Constants.App.githubURL)
                            .underline()
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "arrow.up.right.square")
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                }
                .help(Localization.string("Open the GitHub repository in your browser."))
                .accessibilityHint(Text(Localization.string("Open the GitHub repository in your browser.")))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
