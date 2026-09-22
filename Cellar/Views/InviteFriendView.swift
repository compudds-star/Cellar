import SwiftUI
import CoreImage.CIFilterBuiltins

/// Hands a friend everything their app needs to look up prices: the endpoint and,
/// if this device has one, the access token — as a QR code to scan off the screen,
/// or as a link to text or email when they aren't with you.
///
/// The token is read from the Keychain and rendered here, on the phone that already
/// holds it. Nothing is written to a file or typed anywhere it could be captured,
/// unless the person deliberately shares it.
struct InviteFriendView: View {
    @State private var sharing = false
    @State private var copied = false

    private let invite = ValuationConfig.shareableInvite

    private var link: URL? { invite?.url }

    /// What goes into a message or email: the instruction and the link together,
    /// since a `cellar://` link isn't always tappable in a chat app.
    private var shareText: String {
        guard let link else { return "" }
        return """
        Here's the setup for Cellar's wine pricing. On your iPhone, with Cellar \
        installed, open this link (or scan the picture):

        \(link.absoluteString)
        """
    }

    var body: some View {
        Group {
            if let link, let invite {
                Form {
                    Section {
                        VStack(spacing: 12) {
                            qrImage(for: link.absoluteString)
                            Text(invite.host)
                                .font(.footnote.weight(.semibold))
                            Text(invite.token == nil
                                 ? "No access token on this device — the link just sets the server."
                                 : "Includes your access token.")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } footer: {
                        Text("Point their camera at this code, and their Cellar asks before it accepts it.")
                    }

                    Section {
                        Button {
                            sharing = true
                        } label: {
                            Label("Share code and link", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = link.absoluteString
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    } footer: {
                        Text("Messaging or emailing sends the code as a picture and the link as text — whichever their phone handles. If the link isn't tappable in their chat app, they can paste it into Safari.")
                    }

                    Section {
                        Label {
                            Text("Anyone who gets this can look up prices on your server, at your expense. Send it only to people you mean to, and if it gets out, rotate the token on the server — it cuts off every phone holding the old one.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No pricing server set", systemImage: "link.badge.plus")
                } description: {
                    Text("Add a pricing endpoint in Settings first — that's what an invite passes on.")
                }
            }
        }
        .navigationTitle("Invite a friend")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $sharing) {
            if let image = InviteQRCode.image(for: link?.absoluteString ?? "") {
                ShareSheet(items: [image, shareText])
            } else {
                ShareSheet(items: [shareText])
            }
        }
    }

    @ViewBuilder
    private func qrImage(for text: String) -> some View {
        if let image = InviteQRCode.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)          // keep the modules crisp when scaled
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .padding(12)
                .background(.white)            // a QR needs a light quiet zone, in either theme
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Setup QR code")
        } else {
            Text("Couldn't draw the code — use the link instead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// QR generation for the invite link. Black on white, medium error correction —
/// enough redundancy to survive a camera reading it off a screen.
enum InviteQRCode {
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
