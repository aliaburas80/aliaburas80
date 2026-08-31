import Foundation
import Darwin

if let trapExit = ImageDownsampler.runTrapHelperIfRequested() {
    exit(trapExit)
}
if let decodeExit = ImageDownsampler.runDecodeHelperIfRequested() {
    exit(decodeExit)
}
if let selfTestExit = ImageDownsampler.runSelfTestIfRequested() {
    exit(selfTestExit)
}

FileHandle.standardError.write(Data("apc-decoder-exact: expected self-test/helper arguments\n".utf8))
exit(64)
