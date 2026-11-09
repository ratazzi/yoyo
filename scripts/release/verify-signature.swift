import Foundation
import CryptoKit

let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
guard let publicData = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    FileHandle.standardError.write(Data("Invalid public key or signature encoding\n".utf8))
    exit(1)
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
guard key.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Update signature does not match SPARKLE_PUBLIC_KEY\n".utf8))
    exit(1)
}
