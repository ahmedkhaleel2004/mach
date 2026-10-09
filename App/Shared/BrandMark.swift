import CryptoKit
import Foundation
import Security

/// Checks a company's logo certificate the way a mail service does before showing the logo beside its mail.
///
/// A logo only counts if a certificate authority that vouches for trademarks signed it for that exact domain.
/// The logo is then taken out of the certificate itself, so what is shown is what was vouched for.
enum BrandMark {
    /// The authorities that issue these certificates, by the fingerprint of their root certificate.
    private static let roots: Set<String> = [
        "504386c9ee8932fecc95fade427f69c3e2534b7310489e300fee448e33c46b42", // DigiCert Verified Mark Root CA
        "cd122cb877c6928b9017b0f0b80dbd508196300bbd03cd7356c3beef524e7e0b", // GlobalSign Verified Mark Root R42
        "8f9d1b7698886782a599b48510651c66a1aa0c5ca3192097bdc68534154bd30d", // SSL.com VMC RSA Root CA 2024
    ]
    /// Marks a certificate as being for a brand logo and nothing else (1.3.6.1.5.5.7.3.31).
    private static let purpose = Data([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x1F])

    /// The logo (an SVG file) from a certificate chain in PEM form, or nil unless every check passes.
    static func logo(pem: Data, domain: String) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        var chain: [(der: Data, certificate: SecCertificate)] = []
        for block in text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().prefix(6) {
            guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first,
                  let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
            chain.append((der, certificate))
        }
        guard chain.count >= 2, let leaf = chain.first else { return nil }
        let trusted = chain.filter { roots.contains(SHA256.hash(data: $0.der).map { String(format: "%02x", $0) }.joined()) }
        guard !trusted.isEmpty else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain.map(\.certificate) as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust,
              SecTrustSetAnchorCertificates(trust, trusted.map(\.certificate) as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { return nil }
        let bytes = [UInt8](leaf.der)
        let parts = extensions(in: bytes)
        // Issued for this domain, for use as a brand logo, and carrying the logo.
        guard let alternativeNames = parts[[0x55, 0x1D, 0x11]], names(bytes, in: alternativeNames).contains(domain.lowercased()),
              let uses = parts[[0x55, 0x1D, 0x25]], Data(bytes[uses]).range(of: purpose) != nil,
              let logotype = parts[[0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x0C]] else { return nil }
        // The logo sits in its extension as one text value: a tag, its length, then the text.
        let marker = [UInt8]("data:image/svg+xml;base64,".utf8)
        guard let offset = Data(bytes[logotype]).range(of: Data(marker))?.lowerBound else { return nil }
        let at = logotype.lowerBound + offset
        guard at - 5 >= logotype.lowerBound else { return nil }
        let length: Int
        if bytes[at - 2] == 0x16, bytes[at - 1] < 0x80 { length = Int(bytes[at - 1]) }
        else if bytes[at - 3] == 0x16, bytes[at - 2] == 0x81 { length = Int(bytes[at - 1]) }
        else if bytes[at - 4] == 0x16, bytes[at - 3] == 0x82 { length = Int(bytes[at - 2]) << 8 | Int(bytes[at - 1]) }
        else if bytes[at - 5] == 0x16, bytes[at - 4] == 0x83 { length = Int(bytes[at - 3]) << 16 | Int(bytes[at - 2]) << 8 | Int(bytes[at - 1]) }
        else { return nil }
        guard length > marker.count, at + length <= logotype.upperBound else { return nil }
        let encoded = bytes[(at + marker.count)..<(at + length)]
        guard let packed = Data(base64Encoded: Data(encoded)), packed.count > 18, packed[0] == 0x1F, packed[1] == 0x8B, packed[3] == 0,
              let svg = try? (packed.subdata(in: 10..<packed.count - 8) as NSData).decompressed(using: .zlib) as Data,
              svg.count > 50, svg.count < 2_000_000 else { return nil }
        return svg
    }

    /// One piece of a certificate: what kind it is, and where its contents start and end.
    private static func piece(_ bytes: [UInt8], at index: Int) -> (tag: UInt8, body: Range<Int>)? {
        guard index + 2 <= bytes.count else { return nil }
        var length = Int(bytes[index + 1])
        var start = index + 2
        if length >= 0x80 {
            let count = length & 0x7F
            guard count >= 1, count <= 3, start + count <= bytes.count else { return nil }
            length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard start + length <= bytes.count else { return nil }
        return (bytes[index], start..<start + length)
    }

    /// A certificate's extensions, found by walking its structure from the top: each one's identifier and where
    /// its value lies. Nothing is found by searching for a run of bytes, so text that a company chose for itself
    /// elsewhere in the certificate can never be mistaken for one.
    private static func extensions(in bytes: [UInt8]) -> [[UInt8]: Range<Int>] {
        guard let whole = piece(bytes, at: 0), whole.tag == 0x30, whole.body.upperBound == bytes.count,
              let signed = piece(bytes, at: whole.body.lowerBound), signed.tag == 0x30 else { return [:] }
        var found: [[UInt8]: Range<Int>] = [:]
        var at = signed.body.lowerBound
        while at < signed.body.upperBound, let field = piece(bytes, at: at) {
            at = field.body.upperBound
            guard field.tag == 0xA3, let list = piece(bytes, at: field.body.lowerBound), list.tag == 0x30,
                  list.body.upperBound == field.body.upperBound else { continue }
            var next = list.body.lowerBound
            while next < list.body.upperBound, let item = piece(bytes, at: next), item.tag == 0x30 {
                next = item.body.upperBound
                guard let label = piece(bytes, at: item.body.lowerBound), label.tag == 0x06 else { return [:] }
                var value = label.body.upperBound
                // An optional "critical" flag comes before the value.
                if let flag = piece(bytes, at: value), flag.tag == 0x01, flag.body.upperBound < item.body.upperBound { value = flag.body.upperBound }
                guard let wrapper = piece(bytes, at: value), wrapper.tag == 0x04, wrapper.body.upperBound == item.body.upperBound else { return [:] }
                let key = Array(bytes[label.body])
                // The same extension twice is not a certificate to trust.
                guard found[key] == nil else { return [:] }
                found[key] = wrapper.body
            }
        }
        return found
    }

    /// The DNS names in a "subject alternative name" extension.
    private static func names(_ bytes: [UInt8], in value: Range<Int>) -> [String] {
        guard let list = piece(bytes, at: value.lowerBound), list.tag == 0x30, list.body.upperBound == value.upperBound else { return [] }
        var found: [String] = []
        var at = list.body.lowerBound
        while at < list.body.upperBound, let entry = piece(bytes, at: at) {
            if entry.tag == 0x82, let name = String(bytes: bytes[entry.body], encoding: .ascii) { found.append(name.lowercased()) }
            at = entry.body.upperBound
        }
        return found
    }
}
