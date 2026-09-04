import Crypto
import Foundation
import MozzPairing

func hexOf(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hexData(_ s: String) -> Data {
    var out = Data(); var i = s.startIndex
    while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
        out.append(UInt8(s[i..<j], radix: 16)!); i = j
    }
    return out
}

// Fixed inputs. Nothing random: a fixture that changes between runs is not a fixture.
let pub = Data((0..<32).map { UInt8($0) })
let mem = Data((0..<32).map { UInt8(0x80 &+ $0) })
let nonceA = Data((0..<16).map { UInt8(0xA0 &+ $0) })
let nonceB = Data((0..<16).map { UInt8(0xB0 &+ $0) })
let secret = Data(repeating: 0x2B, count: 32)

let qr = try Pairing.encodeQR(.init(publicKey: pub, nonce: nonceA))
let commit = Pairing.commitment(nonceA: nonceA)
let transcript = try Pairing.transcriptHash(
    joinerPublicKey: pub, memberPublicKey: mem, nonceA: nonceA, nonceB: nonceB)
let swapped = try Pairing.transcriptHash(
    joinerPublicKey: mem, memberPublicKey: pub, nonceA: nonceA, nonceB: nonceB)
let basic = Pairing.digits(sharedSecret: secret, transcriptHash: transcript)
let info = Pairing.channelInfo(transcriptHash: transcript)

// A stream whose FIRST word is above the rejection limit, so the correct answer
// comes from the SECOND. An implementation that reduces the first instead of
// discarding it produces 967295 here and passes every other case in this file.
let rejectStream = "ffffffff" + "000000ff" + String(repeating: "00", count: 24)
let rejectValue = Pairing.uniformValue(from: Array(hexData(rejectStream)))

// A secret chosen so the digits begin with zeros — "42" instead of "000042" is a
// real rendering bug and it only shows up when the number is small.
var zeroSecret = Data(repeating: 0x00, count: 32)
var zeroDigits = ""
for probe in 0..<20000 {
    zeroSecret = withUnsafeBytes(of: UInt64(probe).bigEndian) { Data($0) } + Data(repeating: 0x11, count: 24)
    let d = Pairing.digits(sharedSecret: zeroSecret, transcriptHash: transcript)
    if d.hasPrefix("00") { zeroDigits = d; break }
}

struct Case: Encodable { let name: String; let note: String; let input: [String: String]; let expected: String }
struct File: Encodable { let cases: [Case] }

let cases: [Case] = [
    .init(name: "qr-payload-canonical",
          note: "field order, unpadded base64url, and the MOZZ1: prefix",
          input: ["publicKey": hexOf(pub), "nonce": hexOf(nonceA)],
          expected: qr),
    .init(name: "commit-binding",
          note: "the commitment covers the label AND the nonce, not the nonce alone",
          input: ["nonceA": hexOf(nonceA)],
          expected: hexOf(commit)),
    .init(name: "transcript-order",
          note: "fixed field order; every field fixed-width so none can be confused for its neighbour",
          input: ["joinerPublicKey": hexOf(pub), "memberPublicKey": hexOf(mem),
                  "nonceA": hexOf(nonceA), "nonceB": hexOf(nonceB)],
          expected: hexOf(transcript)),
    .init(name: "transcript-swapped",
          note: "swapping joiner and member must change the hash, or the transcript does not bind who is who",
          input: ["joinerPublicKey": hexOf(mem), "memberPublicKey": hexOf(pub),
                  "nonceA": hexOf(nonceA), "nonceB": hexOf(nonceB)],
          expected: hexOf(swapped)),
    .init(name: "sas-digits-basic",
          note: "the ordinary derivation",
          input: ["sharedSecret": hexOf(secret), "transcriptHash": hexOf(transcript)],
          expected: basic),
    .init(name: "sas-digits-leading-zeros",
          note: "000042 must not render as 42",
          input: ["sharedSecret": hexOf(zeroSecret), "transcriptHash": hexOf(transcript)],
          expected: zeroDigits),
    .init(name: "sas-digits-rejection",
          note: "first word is above the limit and MUST be discarded; reducing it gives 967295 and passes every other case",
          input: ["stream": rejectStream],
          expected: String(format: "%06u", rejectValue)),
    .init(name: "channel-info-binding",
          note: "info binds the transcript, so a seal cannot be replayed into another ceremony",
          input: ["transcriptHash": hexOf(transcript)],
          expected: hexOf(info)),
]

let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try enc.encode(File(cases: cases)))
