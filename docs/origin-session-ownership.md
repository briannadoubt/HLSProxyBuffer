# Origin session ownership

ProxyHLSPlayer uses one ephemeral origin URLSession for its manifest and segment
requests. This allows connection reuse within a player without sharing media
caches, analytics, or session state between players. The player owns invalidation.
The per-host connection limit now applies jointly to its manifest and segment
requests, rather than independently to two sessions.

When the network policy changes, the player installs a new session in its segment
fetcher before finishing the old session. Existing requests may finish on the old
session. New requests use the new policy. Normal stop/reload retains the session;
player destruction invalidates it.

HLSSegmentFetcher.updateSession(_:networkPolicy:) is additive. It adopts an
externally owned session; the caller must retain and invalidate that session.
Replacing an internally owned session finishes its outstanding tasks. Replacing
an externally owned session never invalidates it. Existing initializers and
updateNetworkPolicy(_:) retain their ownership behavior. No caller migration is
required. Device performance benefit remains to be measured.
