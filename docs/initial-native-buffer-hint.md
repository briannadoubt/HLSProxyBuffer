# Initial native buffer hint

`ProxyPlayerConfiguration.BufferPolicy.initialNativeBufferDuration` is an optional
AVFoundation hint applied to each new `AVPlayerItem` before it is attached to an
`AVPlayer`. This avoids an initial default-buffering window when an application
already intends to apply a specific native hint.

The default is `nil`, preserving AVFoundation's initial behavior. Explicit values
must be finite and nonnegative; zero requests the native default buffering policy.
This is separate from the proxy scheduler's `targetBufferSeconds`. Neither value
is a hard download, memory, or latency limit.

The initial hint is reapplied on item replacement/reload. Unrelated configuration
updates do not overwrite an application's later visibility-specific native hints.
Performance and stall behavior must be compared on the application's real workload;
this API alone does not establish a startup, CPU, bandwidth, or energy gain.
