// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Entry point of Kai's network system extension. macOS starts this process
// (as root) once the user has approved the extension; NetworkExtension then
// creates FilterDataProvider, named in Info.plist.
import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
