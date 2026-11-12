# Third-party notices

Autarx builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is distributed
under; consult the upstream license files for full terms. The Rivet
toolchain is a first-party TurLamAI project consumed as a pinned package —
not third-party code — so it is not listed here.

## Racket CS runtime

Every platform host embeds the statically linked Racket CS runtime
([racket/racket](https://github.com/racket/racket), 9.x), which also ships
inside the CLI zip and the update payloads. Racket is distributed under
the MIT license and the Apache License 2.0, at your option; the Racket CS
runtime system additionally embeds Chez Scheme, distributed under the
Apache License 2.0 (per Racket's `LICENSE.txt`).

## crypto (Racket package)

The CLI update channel verifies Ed25519 signatures through the Racket
[crypto](https://github.com/rmculpepper/crypto) package (compiled into the
embedded runtime image), distributed under the Apache License 2.0.

## GTK 4 and libadwaita

The Linux host is a GTK 4 application built against libadwaita; both
libraries are licensed under the GNU Lesser General Public License,
version 2.1 or later. Depending on the Linux install shape the libraries
come from two places:

- deb / rpm: GTK 4, libadwaita and their system dependencies are the only
  runtime dependencies and are supplied by the distribution.
- `.AppImage` / tar.gz: the AppImage bundles the GTK 4 library closure the
  workbench needs, staged by the Rivet toolchain from the build
  distribution's packages (same LGPL-2.1-or-later terms); the tar.gz relies
  on the distribution's libraries.

## AppImageKit runtime (`.AppImage` artifacts)

`.AppImage` release artifacts contain the type-2 AppImage runtime from
[AppImage/AppImageKit](https://github.com/AppImage/AppImageKit), licensed
MIT. The build tool is the checksum-verified official `appimagetool` 1.9.0
release fetched by the Rivet toolchain (`rivet-cli/appimage.rkt`).
AppImageKit's license does not apply to the contents of the AppImage:
those are Autarx's proprietary payload plus the entries above.

## Microsoft Windows App SDK and C++/WinRT (Windows host)

The Windows workbench builds against the NuGet packages
`Microsoft.WindowsAppSDK` 2.4.0 and `Microsoft.Windows.CppWinRT`
(both MIT-licensed, see `windows/RivetHost.vcxproj`). The Windows App SDK
runtime is deployed on the target machine as Microsoft's framework package
under its own terms — the Autarx MSI does not republish it.
