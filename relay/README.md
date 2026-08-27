# Mozz relay control plane

This Worker is not the relay data path. Clients upload ciphertext directly to
Backblaze B2's native API and read it through Cloudflare. The Worker does one
rare job: mint or renew a B2 application key restricted to one random channel
prefix.

It stores no account, user, device, channel, or key. Its required secrets are:

- `B2_MASTER_KEY_ID`
- `B2_MASTER_APPLICATION_KEY`
- `B2_ACCOUNT_ID`
- `B2_BUCKET_ID`

The master key needs `writeKeys` and should have no file capabilities. Set
secrets with `wrangler secret put`; never put them in this file or
`wrangler.jsonc`.

`B2_READ_ENDPOINT` currently uses B2's verified public download host so a
deployment is functional before DNS exists. Replace it with
`https://sync.mozzmusic.com/file/mozz-relay` after that hostname is proxied
through Cloudflare; keys minted before the change keep the direct endpoint
until their next renewal.

`CHANNEL_RATE_LIMITER` is required in production. The Worker fails closed if
the binding is absent. `ALLOW_UNLIMITED_DEV=true` exists only for local tests.

## Endpoints

- `POST /v1/channels` with `{"channelId":"<random base64url>"}`
- `POST /v1/channels/{channelId}/renew` with the existing child key as HTTP
  Basic credentials

The response is the `B2RelayConfiguration` JSON that Mozz seals during the
pairing ceremony. Keys last 90 days by default and can access only
`c/{channelId}/`.

Run the dependency-free tests with:

```bash
npm test --prefix relay
```
