# Stop refreshing completed alternate playlists

Alternate audio and subtitle playlists containing `EXT-X-ENDLIST` no longer
start a refresh task. A live alternate playlist continues refreshing until a
successful fetch observes ENDLIST; the task then exits. Fetch failures preserve
the existing retry loop. Rendition selection and the cached rewritten playlist
remain available. This changes no public API.

The integration regression counts real loopback origin requests. Before the
fix, an initially ended audio playlist and subtitle playlist were each fetched
four times during the observation window instead of once. The fixed test
requires one request each. A second test returns live playlists for two requests
and ENDLIST on the third; it requires exactly three requests for each rendition
and verifies both remain exposed for selection.

This removes unnecessary requests for these workloads. It does not establish
CPU or energy gains, and does not resolve the separate synthetic feed CPU gap.
Supplemental/rendition-report playlists now track ENDLIST separately and stop
their refresh tasks as well. The I-frame fixture independently reproduced four
requests instead of one before that fix. Initially-ended and live-to-ended tests
cover audio, subtitles and I-frame playlists. A repeated-load test verifies an
ended session does not suppress live refresh in the next session. Report-path
state clears during rendition teardown.
