# ISO / UDF Disc Images — a Peach Commander plugin

Opens CD, DVD and Blu-ray images as browsable folders in
[Peach Commander](https://github.com/hkiam/PeachCommander): **ISO 9660**, **Joliet**,
**Rock Ridge**, **UDF**, and the **El Torito** boot images a bootable disc carries.

It is also the worked example for
[the plugin SDK](https://github.com/hkiam/PeachCommanderPluginSDK) — a complete third-party plugin
with its own build, its own tests, its own release, and no dependency on the application's source.

```
./build.sh dist --package     →  dist/ISO9660-1.0.0.pcplug
```

Double-click the `.pcplug`, or press Enter on it in a Peach Commander panel.

## What it adds

Peach Commander can already walk into an `.iso` — through `bsdtar`, one subprocess per file. This
plugin replaces that path, and the difference is not cosmetic:

| | built-in (`bsdtar`) | this plugin |
|---|---|---|
| ISO 9660, Joliet, Rock Ridge | yes | yes |
| **UDF** | **cannot open the file at all** | yes |
| Modification times | every file reports the *container's* timestamp | each file's own, from the disc |
| Reading one file | a subprocess that re-scans the image from the start | a seek |
| Boot images (El Torito) | not listed | listed under `[boot]/` |
| Volume label, publisher, date | not shown | `.disc-info.txt` at the root |
| Symlinks | shown as such | shown as such, with the target as the contents |
| Recognised without the right extension | no | yes — by `CD001` / `NSR0x`, so a `.img` or an extensionless dump opens |

Nothing on the host's side had to change for it to take over: a packer plugin that claims `iso` is
consulted **before** the built-in readers, so installing this plugin is the whole of the switch,
and disabling it puts the old behaviour back.

## Install

Download from the [releases](../../releases). Which file depends on the version of Peach Commander
you have, and the difference is only about how it installs — the plugin itself is the same:

**Peach Commander 0.9.0 or later** — take `ISO9660-<version>.pcplug` and open it any of these ways.
All four show the same confirmation first, naming the plugin and the file types it will take over:

- double-click it in the Finder
- press Enter on it in a Peach Commander panel
- drag it onto Configuration ▸ Plugins…
- Configuration ▸ Plugins… ▸ **Install…**

**Peach Commander 0.8.x** — take `ISO9660-<version>.zip` instead, and use
Configuration ▸ Plugins… ▸ **Install from Folder…**. Those versions do not know the `.pcplug`
extension, so the file chooser will not offer it and a double-click does nothing; the `.zip` is the
same package under a name they do accept. Both files contain exactly the same plugin bundle.

The plugin needs 0.8.0 or later to run at all (`PCPluginMinHostVersion`). It uses one optional
export, `ReadEntryData`, that hosts before 0.9.0 do not look for — there it falls back to whole-file
extraction rather than failing.

## Build from source

```
git clone https://github.com/hkiam/PeachCommanderPluginISO.git
cd PeachCommanderPluginISO
./build.sh                      # into ~/Library/Application Support/PeachCommander/plugins
./build.sh dist --package       # into ./dist, plus the .pcplug package
swift test                      # 23 tests, including the plugin driven over its C ABI
```

The SDK is a SwiftPM dependency, so there is nothing else to clone — `build.sh` takes the headers
from the resolved checkout. If you keep a clone of the SDK beside this one, it uses that instead, so
you can work on both at once.

`build.sh` is short on purpose — it is meant to be read. It is one `swiftc -emit-library` per
architecture, `lipo`'d together, into a bundle directory with an `Info.plist`. That is the whole of
what a Swift plugin is.

Check the result the way the host will:

```
swift run --package-path .build/checkouts/PeachCommanderPluginSDK pcplug-validate \
    dist/ISO9660.pcxplugin --open some-image.iso
```

## How it is put together

| File | What it does |
|---|---|
| `Sources/ISOPlugin/ABI.swift` | **the only file that knows about Peach Commander** — the ten C entry points |
| `Sources/ISOPlugin/ImageReader.swift` | `pread` on the image, and the both-endian integer fields ISO 9660 is made of |
| `Sources/ISOPlugin/ISO9660.swift` | volume descriptors, directory records, and which of three name schemes to believe |
| `Sources/ISOPlugin/RockRidge.swift` | the SUSP entries in a record's tail: real names, modes, times, symlinks |
| `Sources/ISOPlugin/UDF.swift` | ECMA-167: anchor → partition → file set → file entries |
| `Sources/ISOPlugin/ElTorito.swift` | the boot catalog, and the images outside the directory tree |
| `Sources/ISOPlugin/DiscImage.swift` | one tree out of the two or three a disc may carry |
| `Sources/ISOPlugin/TreeCache.swift` | parse once per image, not once per question the host asks |
| `Plugin/Info.plist` | the manifest — what the plugin claims, read without loading its code |

Everything above `ABI.swift` is an ISO reader that knows nothing about the host. That split is the
point: the part that is specific to Peach Commander is 260 lines with a comment on every trap.

## Choices worth knowing about

**Which tree wins.** A disc can describe itself as ISO 9660, Joliet and UDF at once, and the three
need not agree. The rule: read them all, keep whichever lists more files, and let UDF win a tie.
Rock Ridge always decides the *attributes* — a symlink is a symlink whatever it is called — but it
decides the *names* only when it actually carries any, because `hdiutil` writes Rock Ridge
permissions with plain ISO 9660 names while Joliet holds the real ones. The choice is written into
`.disc-info.txt`, so it can be seen rather than guessed at.

**Symlink targets.** Rock Ridge has an `SL` entry for these, and some writers use it. `hdiutil`
does not: it marks the link in the POSIX mode and stores the target as the file's ordinary
contents. Both are read, so a symlink is never shown pointing nowhere.

**Boot image sizes.** El Torito records a sector count, and many writers put 4 there (2 KB)
regardless of how large the image really is, because the firmware only reads the first part. The
size shown is what the disc claims. There is no field that says what the author meant.

**Not implemented**, and detected rather than mis-read: UDF virtual, sparable and metadata
partition maps (packet-written CD-RW, and some UDF 2.50 Blu-rays — those are read through the
physical partition instead), multi-session discs beyond the first session, and writing of any kind.
The plugin is read-only and says so through `GetPackerCaps`, so the host never offers to pack.

## Tests

`swift test` runs 22 tests in two groups.

`DiscImageTests` drives the reader directly. Every fixture is written by **`hdiutil`**, not by this
plugin — a reader and a writer from the same hand agree with each other and prove nothing — and the
listings are cross-checked against **`bsdtar`**, a third independent implementation. One test
asserts that `bsdtar` finds *nothing* in the UDF-only image, because that is the claim the plugin
rests on, and if it ever stops being true this README should change.

`PluginABITests` builds the bundle exactly as `build.sh` does, `dlopen`s it, and calls the exports
by name in the order the host calls them. It imports nothing from the plugin: a mistake in how the
plugin uses its own header would otherwise cancel itself out.

Regenerate the fixtures with `Tools/make-fixtures.sh`; `Tests/ISOPluginTests/Fixtures/manifest.txt`
records each image's sha256 and the exact command that produced it.

## Licence

Apache-2.0. See `LICENSE`.
