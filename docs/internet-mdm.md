# Pre-approving Kai's Internet watching on managed Macs

Turning on Internet watching asks the user twice: once to allow Kai's system
extension (System Settings), then to allow Kai to filter network content.
On Macs your organisation manages, an MDM profile can approve both in advance,
so users see neither prompt.

Kai ships no MDM code. These are the standard Apple payloads:

| What | Payload | Values |
| --- | --- | --- |
| Allow the system extension | `com.apple.system-extension-policy` | Team ID `KD446VDTM2`, extension `io.github.sameehj.kai.network`, type `NetworkExtension` |
| Allow the content filter | `com.apple.webcontent-filter` | `FilterType` = `Plugin`, `PluginBundleID` = `io.github.sameehj.kai`, `FilterDataProviderBundleIdentifier` = `io.github.sameehj.kai.network`, `FilterSockets` = true, `FilterPackets` = false, `FilterDataProviderDesignatedRequirement` from `codesign -d -r - /Applications/Kai.app/Contents/Library/SystemExtensions/io.github.sameehj.kai.network.systemextension` |

Internet watching stays **Watch only**: the filter records which destinations
agents connect to and blocks nothing in this release.

Check the values against the Kai version you deploy (`kai version`) and test
the profile on one Mac before rolling it out.
