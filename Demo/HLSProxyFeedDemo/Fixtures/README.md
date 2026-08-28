# Feed fixture provenance

The media in `short-a`, `short-b`, and `long-form` is generated entirely from
FFmpeg `lavfi` color and sine sources by `Scripts/generate-feed-fixtures.sh`.
It contains no third-party footage, artwork, voices, or trademarks. The files
are repository-owned test data and may be used under this repository's license.

The canonical committed assets were generated with FFmpeg 8.1.1 using H.264
Main Profile video, mono AAC audio, one-second independent fragments, and fMP4
HLS version 7 playlists. The two short fixtures intentionally share a codec,
resolution, frame rate, audio layout, and segment cadence so they can exercise
compatible clip stitching. `long-form` provides eight seconds of media. The
hand-authored `live/playlist.m3u8` is a rolling three-segment window over the
last three long-form fragments and intentionally omits `EXT-X-ENDLIST`.

At runtime the demo origin gives the checked-in short media twenty-four stable,
unique `/feed/feed-NN/` URL namespaces. Generated manifests use two- and
three-segment timelines while the underlying fragments retain their real,
slightly varied byte sizes. The origin also supplies deterministic response
latency, throughput, transient-failure, offline, validator, byte-range, and
bounded request-accounting controls for tests and qualification scenarios.

Regeneration is never required to run tests or CI. To deliberately replace the
canonical generated media, install FFmpeg and run:

```sh
Scripts/generate-feed-fixtures.sh
```

Review and commit every resulting binary difference. FFmpeg encoder revisions
can produce byte-level changes even when stream semantics remain equivalent.
