import AppKit

/// The same truthful operation state appears in the menu and the floating download panel.
@MainActor
final class WallpaperActivityView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Daystar")
    private let messageLabel = NSTextField(wrappingLabelWithString: "Ready for a little more universe.")
    private let progress = NSProgressIndicator()
    private let cancelButton: NSButton

    init(cancelTarget: AnyObject, action: Selector) {
        cancelButton = NSButton(title: "Cancel", target: cancelTarget, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: 108))
        let star = NSImageView()
        star.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Daystar")
        star.contentTintColor = .systemYellow
        star.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.isHidden = true
        for view in [star, titleLabel, messageLabel, progress, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            star.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            star.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            star.widthAnchor.constraint(equalToConstant: 24),
            star.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: star.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cancelButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: messageLabel.trailingAnchor),
            progress.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 9),
            progress.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(message: String, fraction: Double?, busy: Bool, error: Bool) {
        titleLabel.stringValue = busy ? "Daystar is at work" : error ? "Something needs attention" : "Daystar"
        messageLabel.stringValue = message
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
        cancelButton.isHidden = !busy
        progress.isHidden = !busy
        if busy {
            progress.isIndeterminate = fraction == nil
            if let fraction {
                progress.stopAnimation(nil)
                progress.doubleValue = fraction
            } else {
                progress.startAnimation(nil)
            }
        } else {
            progress.stopAnimation(nil)
        }
        setAccessibilityLabel("Daystar: \(message)")
    }
}
