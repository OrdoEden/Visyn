# MMWormhole 2.0.0

Source: https://github.com/mutualmobile/MMWormhole
Tag: `2.0.0`, commit `2d54d0a8924f52fc661f3d8dad07ffa03b67c5a6`.
MIT license retained in LICENSE and source headers.

The upstream release has no Swift Package manifest. This package vendors its
file transport core. The only source adaptation is a `MMWORMHOLE_FILE_ONLY`
guard around WatchConnectivity imports/implementations in MMWormhole.h/.m;
Watch session sources are omitted. SPM builds this as the MMWormhole module.
