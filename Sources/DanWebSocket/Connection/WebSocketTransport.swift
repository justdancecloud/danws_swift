import Foundation

/// Protocol abstracting the WebSocket transport layer.
/// Default implementation uses URLSessionWebSocketTask (Foundation built-in).
public protocol WebSocketTransport: AnyObject {
    func connect(url: URL)
    func send(_ data: Data)
    func disconnect()

    var onOpen: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    var isConnected: Bool { get }
}

/// Default WebSocket transport using URLSessionWebSocketTask.
public final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate {

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var _isConnected = false

    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onError: ((Error) -> Void)?

    public var isConnected: Bool { _isConnected }

    public override init() {
        super.init()
    }

    public func connect(url: URL) {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.webSocketTask(with: url)
        task?.resume()
        listenForMessages()
    }

    public func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if let error = error {
                self?.onError?(error)
            }
        }
    }

    public func disconnect() {
        _isConnected = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        _isConnected = true
        onOpen?()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _isConnected = false
        onClose?()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if _isConnected {
            _isConnected = false
            onClose?()
        } else if error != nil {
            _isConnected = false
            onClose?()
        }
    }

    // MARK: - Message Receiving

    private func listenForMessages() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.onMessage?(data)
                case .string(let text):
                    // Protocol is binary, but handle string messages gracefully
                    if let data = text.data(using: .utf8) {
                        self.onMessage?(data)
                    }
                @unknown default:
                    break
                }
                // Continue listening
                self.listenForMessages()

            case .failure:
                // Connection error -- delegate methods will handle close
                break
            }
        }
    }
}
