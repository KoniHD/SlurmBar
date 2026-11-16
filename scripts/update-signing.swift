#!/usr/bin/env swift
// Release-signing helper for SlurmBar's in-app updater (Ed25519 via CryptoKit).
//
//   swift scripts/update-signing.swift generate
//       Prints a new private key and public key (both base64).
//   SLURMBAR_UPDATE_KEY=<private base64> swift scripts/update-signing.swift sign <file>
//       Writes <file>.sig containing the base64 signature of the file's bytes.
//   swift scripts/update-signing.swift verify <file> <public base64>
//       Checks <file> against <file>.sig.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print("private: \(key.rawRepresentation.base64EncodedString())")
    print("public:  \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard arguments.count == 2, let raw = ProcessInfo.processInfo.environment["SLURMBAR_UPDATE_KEY"],
          let keyData = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("usage: SLURMBAR_UPDATE_KEY=<base64 private key> update-signing.swift sign <file>") }
    let path = arguments[arguments.startIndex + 1]
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let signature = try key.signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print("Signed \(path)")
case "verify":
    guard arguments.count == 3,
          let keyData = Data(base64Encoded: arguments[arguments.startIndex + 2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else { fail("usage: update-signing.swift verify <file> <base64 public key>") }
    let path = arguments[arguments.startIndex + 1]
    guard let data = FileManager.default.contents(atPath: path),
          let text = try? String(contentsOfFile: path + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("cannot read \(path) or its .sig") }
    guard key.isValidSignature(signature, for: data) else { fail("INVALID signature") }
    print("Signature OK")
default:
    fail("usage: update-signing.swift generate | sign <file> | verify <file> <public key>")
}
