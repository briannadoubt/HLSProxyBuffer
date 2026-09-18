# Optional shared loopback listener

`ProxyServerPool` owns one loopback-only HTTP listener. Pass the same pool to
multiple `ProxyHLSPlayer` initializers with `serverPool:` to retain the endpoint
across clip turnover. Omitting it preserves a private server per player. This is
an additive opt-in API; no performance improvement is claimed without measurement.

Each load obtains a new, random URL namespace. Manifest, segment, rendition and
auxiliary URLs retain that prefix. The gateway strips only the registered prefix
before dispatching to the player's frozen router. Retiring a namespace removes
its routes and cancels its in-flight handlers without cancelling sibling players.
A replacement load never reuses its predecessor's namespace. Client-side caches
may still serve previously cached bytes for an old URL; route-retirement tests
must bypass those caches. Old cached bytes cannot become a new load's resources.

A lease retains its pool. Explicit `closeAndWait()` removes admission immediately
and waits for cooperative route cancellation; deinitialization also removes the
namespace and cancels its handlers. Bytes already handed to a shared connection
may finish sending. Pool capacity bounds registered sessions, while each player's
existing cache/response limits still bound media storage. The caller must keep
those media budgets when sharing a listener.

The pool is lazily started and supports concurrent reservations. Cancelling one
reservation does not cancel shared listener startup. A failed startup can be
retried; stale startup waiters cannot clear a newer startup generation. All
listener connections are closed when the pool is released.

Tests cover distinct namespaces on one port, admission limits, concurrent startup,
lease release, cancellation, retired URLs, sibling survival, playback reload,
alternate renditions, supplemental resources and key rewriting. Physical-device
quality, lifecycle and balanced CPU/latency/bandwidth runs remain required before
an application changes its default transport.
