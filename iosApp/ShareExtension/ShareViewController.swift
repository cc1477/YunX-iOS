import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.text = "正在接收分享内容…"
        let done = UIButton(type: .system)
        done.setTitle("完成", for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.titleLabel?.adjustsFontForContentSizeCategory = true
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, done])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        receive()
    }

    private func receive() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var texts = items.compactMap { $0.attributedContentText?.string }
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                ? UTType.url.identifier : UTType.plainText.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                let text: String?
                if let url = item as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    text = url.absoluteString
                } else { text = item as? String }
                if let text = text, text.utf8.count <= 65_536 {
                    lock.lock(); texts.append(text); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            do {
                try SharePayload.stage(texts.joined(separator: "\n"))
                self?.status.text = "链接已导入。返回 YunX 后会自动解析。\n\n分享内容通过本机剪贴板暂存一小时。"
            } catch {
                self?.status.text = "没有收到可用的链接或文本，请重新分享。"
            }
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
