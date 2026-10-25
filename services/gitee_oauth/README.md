# Browser authorization for snippet backups

The app opens the system browser, waits for authorization, validates the account,
and stores the resulting session in the device's secure storage. Token entry is
available as a fallback. Missing build configuration shows an explanation and
keeps the fallback usable; no OAuth credentials are requested from end users.

## GitHub

1. Register an [OAuth App](https://github.com/settings/developers) owned by the
   project. Enable **Device Flow** in its settings. Keep token expiration disabled
   for this direct device-flow integration; an expiring token requires signing in
   again when it expires. The app requests only the `gist` scope.
2. Set the repository Actions variable `FLCLASHX_GITHUB_CLIENT_ID` to the app's
   public Client ID. No GitHub Client Secret is needed in FlClash.
3. Build a release with `setup.dart`. The release workflow passes the variable
   through to `env.json`. For local packaging, set the environment variable before
   running `dart setup.dart windows` (or the intended platform).

The browser asks for a short verification code. FlClash displays and copies it;
after approval, the app retrieves the token automatically.

## Gitee

Gitee's [authorization-code flow](https://gitee.com/api/v5/oauth_doc) exchanges the
code using a Client Secret. The small Node service in this directory keeps that
secret outside the app and provides a temporary device session for the app to
poll. It also exchanges refresh tokens when an OAuth session expires.

1. Register a [Gitee OAuth application](https://gitee.com/oauth/applications).
   Use `https://YOUR_DOMAIN/gitee/callback` as its callback URL and enable
   `gists` and `user_info` permissions.
2. Install Node.js 22 or later on the server. Set server environment variables:

   ```text
   GITEE_CLIENT_ID=your-app-id
   GITEE_CLIENT_SECRET=your-app-secret
   PUBLIC_URL=https://YOUR_DOMAIN/gitee
   HOST=127.0.0.1
   PORT=8787
   TRUST_PROXY=true
   ```

3. Run `node services/gitee_oauth/server.mjs` under your service manager, with
   those variables available. Use one process: pending sessions live in memory;
   restarting the service cancels pending sign-ins. Completed sessions and refresh
   tokens remain in device secure storage, and no database is required here.
4. Terminate HTTPS on your reverse proxy and preserve the URL prefix. For nginx,
   add this location to the HTTPS server for `YOUR_DOMAIN`:

   ```nginx
   location /gitee/ {
       access_log off;
       client_max_body_size 4k;
       proxy_set_header X-Forwarded-For $remote_addr;
       proxy_pass http://127.0.0.1:8787;
   }
   ```

   Enable `TRUST_PROXY` only behind a trusted proxy that overwrites
   `X-Forwarded-For`, as above. Otherwise leave it unset. Limit external traffic at
   the proxy as appropriate for the deployment. Never log request bodies or
   callback query strings, which contain credentials or authorization codes.
5. Set the Actions variable `FLCLASHX_GITEE_OAUTH_URL` to
   `https://YOUR_DOMAIN/gitee`. This public URL is the only Gitee OAuth setting
   bundled in FlClash. Keep `GITEE_CLIENT_SECRET` exclusively on the server.
6. Build a release. Local packaging reads the same `FLCLASHX_GITEE_OAUTH_URL`
   environment variable through `setup.dart`.

For `flutter run` or a direct `flutter build`, supply the public values using
`--dart-define=FLCLASHX_GITHUB_CLIENT_ID=...` and
`--dart-define=FLCLASHX_GITEE_OAUTH_URL=https://YOUR_DOMAIN/gitee`, or put those
two keys in your ignored `env.json` and use `--dart-define-from-file=env.json`.
Run local host builds only with `--dart-define=SAFE_MODE=true`.

The service generates independent random browser state and device secrets,
checks callback state once, expires sessions after ten minutes, limits pending
sessions and upstream exchanges, and releases a token only to the initiating
device, once. It does not write credentials to disk. Responses disable caching
and referrers; the callback page includes no token. Backup uploads/downloads go
directly between FlClash and Gitee, outside this service.

## Verification

```text
node --test services/gitee_oauth/server.test.mjs
flutter test test/common/github_sync_test.dart test/views/backup_and_restore_test.dart
```

Tests use fake provider responses. Before distributing an enabled build, verify
both flows with the project's registered applications: authorize, read a backup
list, cancel, reject, restart the app, and refresh an expired Gitee session. Live
authorization requires the real Client ID and deployed service; test fixtures
cannot establish that these production settings are correct.
