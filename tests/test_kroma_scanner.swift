import Foundation

@main
struct KromaScannerTests {
    static func main() {
        let log = "Wallet opened /Passes/Cards/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789.pkpass and PDPassLibrary: wrote pass QwErTyUiOpAsDfGhJkLzXcVbNm0123456789"
        let result = KromaCardScanner.cardIDs(in: log)
        precondition(result == ["AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", "QwErTyUiOpAsDfGhJkLzXcVbNm0123456789"])
        precondition(KromaCardScanner.cardIDs(in: "random token AbCdEfGhIjKlMnOpQrStUvWxYz0123456789").isEmpty)
        precondition(KromaCardScanner.cardIDs(in: "selected pass uniqueID: <private>").isEmpty)
        let duplicates = KromaCardScanner.cardIDs(in: "Cards/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789.cache Cards/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789.pkpass")
        precondition(duplicates == ["AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"])
    }
}
