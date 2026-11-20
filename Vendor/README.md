# Syphon dependencies for the command-line build

The Apple silicon package embeds Syphon framework version 5. The files here let a clean checkout build with Apple's Command Line Tools offline. The Xcode project uses the separate `Syphon-Framework` submodule.

| Local path under `SyphonSDK/` | Source |
| --- | --- |
| `Syphon.framework/` | Framework from `SyphonPub.app/Contents/Frameworks/` in SyphonPub 1.2 (24), including its Metal library, bundle metadata and original signature. |
| `Resources/AppIcon.icns`, `Resources/Assets.car` | Compiled app and menu-bar artwork from `SyphonPub.app/Contents/Resources/` in the same release. The editable images are in the project's asset catalog. |
| `Headers/*.h`, `Syphon.modulemap` | Public headers and module map from [Syphon-Framework commit d05537e](https://github.com/Xylopyrographer/Syphon-Framework/tree/d05537e362b39e163e6f20ed6c1008bd7bafa277). |

The official archive is `SyphonPub-1.2.zip`. GitHub lists its SHA-256 as `4a990cc97f0b8db029625ef2362499aee8d0cd943c6535f9b55abf47bca17dad`. The framework executable in the packaged SDK has SHA-256 `698078173f1b7b55286764fa4050cfbcc0cdbf65ea298e7a110f39bd9fcb7543`. [Upstream release](https://github.com/Xylopyrographer/SyphonPub/releases/tag/v1.2) · [GitHub asset checksums](https://github.com/Xylopyrographer/SyphonPub/releases/expanded_assets/v1.2)

The command-line build verifies [SHA256SUMS](SyphonSDK/SHA256SUMS) and the embedded framework signature before compiling. Developers can run the checksum verification from the repository root.

```sh
(cd Vendor/SyphonSDK && shasum -a 256 -c SHA256SUMS)
codesign --verify --strict --deep Vendor/SyphonSDK/Syphon.framework
```

SyphonPub and its artwork are distributed under the [upstream MIT license](../LICENSE). The [Syphon framework and Metal interface notices](../Licenses/Syphon-Framework.txt) apply to the framework and its headers. The application bundle includes both notices in `Contents/Resources/`.
