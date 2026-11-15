import XCTest
@testable import ReoBabyKit

/// Reolink's talk protocol, against answers computed with md5 and openssl: so CommonCrypto on
/// Apple platforms and swift-crypto on Linux are held to the same bytes.
final class BaichuanTests: XCTestCase {
    func testLoginHashIsUppercaseMD5CutTo31() {
        XCTAssertEqual(BaichuanTalk.hash("admin"), "21232F297A57A5A743894A0E4A801FC")
    }

    func testAESKeyIsTheFirst16HexDigitsOfMD5() {
        XCTAssertEqual(String(decoding: BaichuanTalk.aesKey(nonce: "nonce123", password: "secret"), as: UTF8.self),
                       "8D128E7B1920CFF7")
    }

    // printf 'Baichuan says hello to the nursery camera' |
    //   openssl enc -aes-128-cfb -K <hex of "ReoBabyCipher16!"> -iv <hex of "0123456789abcdef"> | xxd -p
    func testAESMatchesOpenSSLAndComesBack() {
        let cipher = Cipher.aes(Array("ReoBabyCipher16!".utf8))
        let plain = Array("Baichuan says hello to the nursery camera".utf8)
        let sealed = cipher.encrypt(plain, offset: 0)
        XCTAssertEqual(sealed.map { String(format: "%02x", $0) }.joined(),
                       "11248a5d6c82fa9c8b73a35b49ec49cca66bcd5e5706fd1591d84d538b54ba393a5b236356254fa8be")
        XCTAssertEqual(cipher.decrypt(sealed, offset: 0), plain)
    }

    func testXORComesBack() {
        let plain = Array("<body>talk</body>".utf8)
        XCTAssertEqual(Cipher.xor.decrypt(Cipher.xor.encrypt(plain, offset: 7), offset: 7), plain)
    }
}
