# Third-party notices

Autarx builds on the components below. Each entry names where the
component enters the shipped artifacts and the license it is distributed
under; consult the upstream license files for full terms. The Rivet
toolchain is a first-party TurLamAI project consumed as a pinned package —
not third-party code — so it is not listed here.

## Racket CS runtime

The Windows host embeds the statically linked Racket CS runtime
([racket/racket](https://github.com/racket/racket), 9.x), which also ships
inside the CLI zip and the update payloads. Racket is distributed under
the MIT license and the Apache License 2.0, at your option; the Racket CS
runtime system additionally embeds Chez Scheme, distributed under the
Apache License 2.0 (per Racket's `LICENSE.txt`).

## crypto (Racket package)

The CLI update channel verifies Ed25519 signatures through the Racket
[crypto](https://github.com/rmculpepper/crypto) package (compiled into the
embedded runtime image), distributed under the Apache License 2.0.

## Microsoft Windows App SDK and C++/WinRT (Windows host)

The Windows workbench builds against the NuGet packages
`Microsoft.WindowsAppSDK` 2.4.0 and `Microsoft.Windows.CppWinRT`
(both MIT-licensed, see `windows/RivetHost.vcxproj`). The Windows App SDK
runtime is deployed on the target machine as Microsoft's framework package
under its own terms — the Autarx MSI does not republish it.
