// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Entry point of Kai's storage system extension (Endpoint Security). macOS
// starts this process as root, once the user approves the extension and it is
// built with the ES entitlement. It creates the ES client and parks on the
// run loop; all the work is in StorageClient.
//
// NOT load-tested on device yet. It defaults to notify mode (observe, never
// block). Real blocking (auth mode) is compiled only with KAI_STORAGE_ENFORCE
// and should first be exercised on a throwaway VM: a slow or wrong auth
// handler can stall file I/O for the whole machine.
import Foundation

let client = StorageClient()
do {
    try client.start()
    NSLog("kai storage extension: started (%@ mode)", client.modeName)
} catch {
    NSLog("kai storage extension: failed to start: %@", String(describing: error))
}
dispatchMain()
