import Foundation

/// Original guide added to an empty library on first launch, so reading works
/// before any import and without a reader device.
enum WelcomeBook {
    static let identifier = UUID(uuidString: "5F0C6E1E-2B8A-4C39-9E0D-7D1B7A4C2E11")!

    static var document: EPUBDocument {
        EPUBDocument(
            title: "Welcome to Pocket Daily",
            language: "en",
            author: "Pocket Daily",
            chapters: [
                .init(title: "A quiet place to read", paragraphs: [
                    "Pocket Daily turns your phone, tablet or Mac into a calm, paper-like reader. There are no feeds, badges or pop-ups here. Just the page you are on and the next one.",
                    "Tap the right side of the page, or swipe left, to turn forward. Tap the left side to go back. Tap the middle to show or hide the controls. A keyboard or a Bluetooth page turner works too: use the arrow keys, Space or Page Down.",
                    "Pages turn instantly, the way they do on an e-paper reader. Choose Aa to change the text size, the font, the spacing, the margins and the page color. Paper is the default; Night is easier on the eyes in the dark.",
                    "Everything you read stays on this device. Pocket Daily has no account and does not collect what you read.",
                ]),
                .init(title: "Bring your own books", paragraphs: [
                    "Add DRM-free EPUB books from Files with the Add button in the Library. Plain text and Markdown files become books when you add them, with Markdown headings as chapters.",
                    "Articles you save from the share sheet appear under Articles. Open one to read it here, or prepare it for your reader.",
                    "Books bought in other stores are usually protected with DRM, and Pocket Daily cannot open them. Many publishers and public-domain libraries offer DRM-free EPUB downloads.",
                ]),
                .init(title: "Continue on your reader", paragraphs: [
                    "If you have an X3 or X4 reader running Pocket Daily or compatible CrossPoint-based firmware, Pocket Daily is also its companion. Customize its Home and Sleep screens, send books and articles, and keep its firmware up to date from the Reader tab.",
                    "A book you send from the Library is the same file you read here, so both devices recognize it as the same book.",
                    "No reader yet? That is fine. Everything in the Library works on its own.",
                ]),
                .init(title: "Keep your place everywhere", paragraphs: [
                    "Pocket Daily keeps your place with no Pocket Daily account or server to set up. Your iPhone, iPad and Mac stay in step through your own iCloud, and a connected X3 or X4 reader exchanges positions over the same local connection that sends books. Each device needs the same book file; share it from the Library.",
                    "Only a fingerprint of the book and your place in it are shared. The book itself never leaves your devices.",
                    "When another device read more recently, or got further, Pocket Daily offers to jump there. It never moves your page without asking.",
                    "Happy reading.",
                ]),
            ],
            identifier: identifier,
            modified: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}
