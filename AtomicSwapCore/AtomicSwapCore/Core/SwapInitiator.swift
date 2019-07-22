import HSCryptoKit

class SwapInitiator {
    enum SwapInitiatorError: Error {
        case swapNotAgreed
        case bailTransactionAlreadySent
        case redeemTransactionAlreadySent
        case bailTransactionCouldNotBeRestored
    }

    private let initiatorBlockchain: ISwapBlockchain
    private let responderBlockchain: ISwapBlockchain
    private let storage: ISwapStorage
    var swap: Swap

    init(initiatorBlockchain: ISwapBlockchain, responderBlockchain: ISwapBlockchain, storage: ISwapStorage, swap: Swap) {
        self.initiatorBlockchain = initiatorBlockchain
        self.responderBlockchain = responderBlockchain
        self.storage = storage
        self.swap = swap
    }

    private func bail() throws {
        guard swap.state == .responded else {
            throw SwapInitiatorError.bailTransactionAlreadySent
        }

        guard let responderRedeemPKH = swap.responderRedeemPKH, let initiatorTimestamp = swap.initiatorTimestamp else {
            throw SwapInitiatorError.swapNotAgreed
        }

        _ = try initiatorBlockchain.sendBailTransaction(
                withRedeemKeyHash: responderRedeemPKH, refundKeyHash: swap.initiatorRefundPKH,
                secretHash: swap.secretHash, timestamp: initiatorTimestamp, amount: swap.amount
        )

        swap.state = .initiatorBailed
        storage.update(swap: swap)
    }

    private func watchResponderBail() throws {
        guard let responderRefundPKH = swap.responderRefundPKH, let responderTimestamp = swap.responderTimestamp else {
            throw SwapInitiatorError.swapNotAgreed
        }

        responderBlockchain.watchBailTransaction(
                withRedeemKeyHash: swap.initiatorRedeemPKH, refundKeyHash: responderRefundPKH,
                secretHash: swap.secretHash, timestamp: responderTimestamp
        )
    }

    private func redeem() throws {
        guard swap.state == .responderBailed else {
            throw SwapInitiatorError.redeemTransactionAlreadySent
        }

        guard let secret = swap.secret, let redeemPKId = swap.redeemPKId,
              let responderRefundPKH = swap.responderRefundPKH, let responderTimestamp = swap.responderTimestamp else {
            throw SwapInitiatorError.swapNotAgreed
        }

        guard let txDetails = swap.responderBailTransaction else {
            throw SwapInitiatorError.bailTransactionCouldNotBeRestored
        }

        let bailTransaction = try responderBlockchain.bailTransaction(from: txDetails)
        try responderBlockchain.sendRedeemTransaction(
                from: bailTransaction,
                withRedeemKeyHash: swap.initiatorRedeemPKH, redeemPKId: redeemPKId, refundKeyHash: responderRefundPKH,
                secret: secret, secretHash: swap.secretHash, timestamp: responderTimestamp
        )
        
        swap.state = .initiatorRedeemed
        storage.update(swap: swap)
    }

}

extension SwapInitiator: ISwapInitiator {

    func proceedNext() throws {
        switch swap.state {
        case .responded:
            try start()
        case .initiatorBailed:
            try watchResponderBail()
        case .responderBailed:
            try redeem()
        default: ()
        }
    }

    func start() throws {
        guard swap.state == .responded else {
            return
        }

        try bail()
        try watchResponderBail()
    }

}

extension SwapInitiator: ISwapBlockchainDelegate {

    func onBailTransactionReceived(bailTransaction: IBailTransaction) {
        guard swap.state == .initiatorBailed else {
            return
        }

        guard let responderBailTransaction = try? responderBlockchain.data(from: bailTransaction) else {
            return
        }

        swap.state = .responderBailed
        swap.responderBailTransaction = responderBailTransaction
        storage.update(swap: swap)

        try? redeem()
    }

    func onRedeemTransactionReceived(redeemTransaction: IRedeemTransaction) {
    }

}
