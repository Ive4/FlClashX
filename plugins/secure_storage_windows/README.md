# Windows secure storage without ATL

Vendored from `flutter_secure_storage_windows` 4.2.2 (BSD-3-Clause; see LICENSE).
Only the Dart implementation is included. The package registers through
`dartPluginClass`; there is no native C++ plugin or CMake target.

The DPAPI implementation, encrypted file format, application support directory,
and locking behavior are unchanged. Legacy native Credential Manager migration
is disabled, even if callers request backward compatibility. Existing DPAPI
records remain readable. An installation using the older native storage must
sign in again; no credentials are copied into plaintext preferences.

Run `flutter pub get` at the application root after switching to this override,
so Flutter regenerates its plugin registrants and drops the old C++ target.
When updating upstream, review the DPAPI implementation and preserve these two
local changes (Dart-only registration and disabled legacy migration).
