# Choose the Bitbucket HTTP transport

Type: grilling
Status: resolved
Blocked by: 03

## Question

Given the measured corporate proxy requirement, should bbr keep `StdHttpClient` as its only production `HttpClient` adapter or add a libcurl adapter, and what configuration, error classification, Credential handling, target support, and acceptance checks follow from that choice?

## Answer

Keep `StdHttpClient` as the only production `HttpClient` adapter. The representative corporate environment permits direct HTTPS access to Bitbucket Cloud, and the live check proved that `StdHttpClient` works there. A libcurl adapter would add a C dependency without meeting a measured requirement.

Keep `HttpClient` as the transport seam. `StdHttpClient` continues to load `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY`, plus their lowercase forms, through `std.http.Client.initDefaultProxies`. Do not add proxy settings to `config.toml`. If a configured proxy value is invalid or unsupported, fail with a sanitized configuration or transport error. Do not retry through a direct connection.

Keep transport errors distinct from `ApiError`. The Bitbucket adapter continues to classify definite HTTP responses as `ApiError` values. Diagnostics may include a transport error name and a Credential-free request location. They must not include Authorization headers, Atlassian Credential values, proxy-auth values, or token-bearing URLs.

Support the four native M19 CI targets without a new C toolchain or runtime dependency: macOS x86_64, macOS aarch64, Linux x86_64, and Linux aarch64.

Acceptance requires:

- hermetic checks for accepted proxy environment names, invalid proxy configuration failure, no direct fallback, transport-error separation, and existing HTTP status classification;
- all four native M19 CI checks to pass;
- one opt-in, Credential-gated direct Bitbucket connectivity check through `StdHttpClient`;
- a sanitized log check that finds no Credential or proxy-auth values.

Do not require a live proxy check because the representative environment has no proxy requirement.
