import UIKit
import UniformTypeIdentifiers

/// The "Chat" entry in the iOS share sheet.
///
/// Deliberately does NOT send anything itself. Sending a message needs the MLS
/// client, the ratchet store, the SQLCipher database and a Tor circuit — the
/// app's entire stack, in a process iOS gives a small memory budget and kills
/// promptly. So the extension only does what it uniquely can: take the content
/// out of the sending app and park it in the shared App Group container. The
/// app collects it (see `IncomingShareChannel`) and shows the "Share to…"
/// picker on its next foreground.
///
/// It does NOT auto-open the app. There is no supported way for a share
/// extension to foreground its container — `NSExtensionContext.open` is
/// Today-widget-only, and the responder-chain `openURL:` hack that used to work
/// is closed on modern iOS (verified dead on iOS 26.5). So rather than flash
/// "Opening Chat…" and bounce the user back to the source app looking like a
/// crash, we show a clear "saved — open Chat to send" confirmation and let them
/// dismiss. The two-step is the honest reality of the platform.
///
/// Counterpart of Android's `IncomingShareStore` — same capture-then-collect
/// shape, except Android CAN route the intent straight into the running app.
class ShareViewController: UIViewController {

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        collectSharedItems()
    }

    // MARK: - UI

    private func buildUI() {
        titleLabel.text = "Saving to Chat…"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.text = ""
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isHidden = true

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, detailLabel, doneButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    /// Swaps the "saving…" state for the final confirmation once the payload is
    /// safely in the App Group. [ok] false means nothing usable was shared or
    /// the write failed.
    private func showResult(ok: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        doneButton.isHidden = false
        if ok {
            titleLabel.text = "Saved to Chat"
            detailLabel.text = "Open the Chat app to choose who to send it to."
        } else {
            titleLabel.text = "Couldn't save that"
            detailLabel.text = "Nothing to share, or it couldn't be read."
        }
    }

    @objc private func doneTapped() {
        finish()
    }

    // MARK: - Collection

    /// Pulls every attachment out of the extension context and writes them to
    /// the App Group, then shows the confirmation.
    private func collectSharedItems() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            showResult(ok: false)
            return
        }
        var text = ""
        var attachments: [[String: String]] = []
        // Providers load concurrently and call back on arbitrary queues; the
        // lock guards the two accumulators, the group waits for all of them.
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            load(provider) { loadedText, attachment in
                lock.lock()
                if let loadedText, !loadedText.isEmpty {
                    text = text.isEmpty ? loadedText : "\(text)\n\(loadedText)"
                }
                if let attachment { attachments.append(attachment) }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let hasContent = !text.isEmpty || !attachments.isEmpty
            let wrote = hasContent &&
                SharedInbox.writePayload(text: text, attachments: attachments)
            self.showResult(ok: wrote)
        }
    }

    /// Resolves one attachment. Order matters: a file URL also conforms to
    /// `public.url`, and a movie/image does not conform to `public.file-url`,
    /// so the most specific types are checked first — otherwise a shared video
    /// would arrive as a text message containing its file path.
    private func load(
        _ provider: NSItemProvider,
        completion: @escaping (String?, [String: String]?) -> Void
    ) {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            loadFile(provider, typeIdentifier: UTType.movie.identifier,
                     fallbackExtension: "mp4", completion: completion)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            loadFile(provider, typeIdentifier: UTType.image.identifier,
                     fallbackExtension: "jpg", completion: completion)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            loadFile(provider, typeIdentifier: UTType.fileURL.identifier,
                     fallbackExtension: "dat", completion: completion)
            return
        }
        // A web link (Safari, YouTube) — sent as a text message, same as
        // Android's EXTRA_TEXT.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                item, _ in
                completion((item as? URL)?.absoluteString, nil)
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                item, _ in
                completion(item as? String, nil)
            }
            return
        }
        completion(nil, nil)
    }

    /// Loads a file-shaped attachment. The provider may hand back a URL, raw
    /// bytes, or a rendered `UIImage` depending on the sending app.
    private func loadFile(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        fallbackExtension: String,
        completion: @escaping (String?, [String: String]?) -> Void
    ) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            if let url = item as? URL {
                completion(nil, SharedInbox.copy(from: url))
                return
            }
            if let data = item as? Data {
                completion(nil, SharedInbox.write(
                    data: data, fileExtension: fallbackExtension))
                return
            }
            if let image = item as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                completion(nil, SharedInbox.write(data: data, fileExtension: "jpg"))
                return
            }
            completion(nil, nil)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
