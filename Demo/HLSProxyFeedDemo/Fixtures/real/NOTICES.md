# Real audiovisual demo media

These media files are third-party works, **not** covered by the repository's
software license. The adjacent `catalog.json` records exact source checksums,
excerpt intervals, output checksums, measured tracks, and decode analysis.

## Big Buck Bunny (Sunflower version)

(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org.
Sunflower rendering: Janus Bager Kristensen (2013).
Music composition and sound design: Jan Morgenstern. Director: Sacha Goedegebure.

Film excerpts: [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/).
[Project's part-film reuse terms](https://peach.blender.org/about/).
The downloaded MP4 also identifies its Sunflower rendering as CC BY 3.0 and
names the Blender Foundation and Janus Bager Kristensen.

Modifications: short excerpts; frame-rate conversion to 24 fps; aspect-preserving
fit/pad; H.264/AAC stereo encoding; two-resolution fMP4 HLS packaging. Original
synchronized film audio is retained. The separately published isolated score is
not included and is **not** offered under this film license.

## NASA STS-135 launch coverage

NASA — STS-135 launch, July 8, 2011. Source: *NASA's Final Space Shuttle Launch
10th Anniversary Replay* (NASA HQ, published July 8, 2021).

Selected launch/onboard-camera excerpts retain original mission commentary and
launch sound. No third-party copyright is identified in the source asset's NASA
metadata. Used factually for educational audiovisual playback testing under
[NASA's media usage guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/).
NASA content generally is not subject to copyright in the United States; do not
interpret that statement as a grant of logo, trademark, publicity, or endorsement
rights. NASA does not endorse HLSProxyBuffer. These prerecorded excerpts are not
a current mission feed. Adopters must independently clear advertising,
promotional, or other uses outside the guidelines.

Modifications: short excerpts; frame-rate conversion to 24 fps; aspect-preserving
fit/pad; H.264/AAC stereo encoding; two-resolution fMP4 HLS packaging.

## Reproduction and validation

From the repository root, put the two checksum-pinned source files named in
`Scripts/real-feed-media-source.json` in a cache **outside** the repository, then
run `swift Scripts/generate-real-feed-media.swift /absolute/source-cache`.
The Bunny download is a ZIP: extract only its named MP4 into that cache.
The generator does not download anything. Source originals must not be committed.

FFmpeg and FFprobe 8.1.1 are maintainer-only tools; normal builds/CI consume the
checked-in corpus without them. The script stages, measures, decodes, validates,
and only then installs the exact `Fixtures/real` directory. Existing output is
moved to a sibling backup before replacement. With a different encoder/build,
review changed bytes and provenance explicitly; do not assume identical output.

The hard caps are 24 short clips + one 32-second cut, at most 240 seconds total,
50 MiB on disk, and 1 MiB per media resource. Decode analysis uses eight evenly
spaced luma samples (at least four distinct), all decoded audio samples (RMS above
-60 dBFS, peak above -40 dBFS), and packet timing (A/V difference at most 100 ms).
It is a technical integrity check, not a claim about physical speakers, perceptual
lip sync, adaptive switching, or device energy.
