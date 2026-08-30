# Metadata-only HTTP responses

`HTTPResponse.representationLength` allows a file-backed handler to describe a
HEAD response without loading the file. `ProxyServer` supplies `includeBody:
false` when serializing HEAD responses; direct users of `encoded` or `headerData`
must do the same. Normal GET framing always uses the actual body size, regardless
of a supplied representation length or Content-Length header.

A 304 response never carries a body and omits Content-Length unless the selected
representation size is explicitly known. The demo ignores Range on HEAD, while
GET retains byte-range support. This follows
[RFC 9110 sections 8.6 and 14.2](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-length).

This is additive; existing GET handlers need no migration. HEAD handlers that
already retain a full body continue to advertise that body's length, but can
instead pass an empty body and its `representationLength` to avoid unnecessary I/O.
