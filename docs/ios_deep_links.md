# iOS deep links

This document describes the custom URL schemes supported by the iOS build.

The iOS runner registers two URL schemes:

- `otzaria://` — primary Otzaria scheme
- `zayit://` — legacy compatibility scheme for supported book links

The iOS `AppDelegate` forwards incoming URLs to the existing Dart external-activation pipeline (`otzaria/external_activation`). The app then parses the URL with `ExternalUriRouter` and dispatches the action from `MainWindowScreen`. This keeps the native iOS layer thin and avoids duplicating navigation logic in Swift.

## Canonical URLs

Use the canonical `otzaria://open/...` form when generating links programmatically:

```text
otzaria://open/library
otzaria://open/search
otzaria://open/search?q=שלום
otzaria://open/detection?q=ברכות ב א
otzaria://open/settings
otzaria://open/settings/design
otzaria://open/tools
otzaria://open/calendar
otzaria://open/history
otzaria://open/bookmarks
otzaria://open/tool/builtin.calendar
otzaria://open/plugin/<plugin-id>
otzaria://open/book/123?index=5
otzaria://open/book/123?index=5&mark
otzaria://open/book/123?index=5&m=טקסט%20להדגשה
otzaria://open/pdf/123?index=12
```

## Short aliases

For iOS shortcuts and manual use, most `open` routes also work in shorter form:

```text
otzaria://library
otzaria://search?q=שלום
otzaria://detection?q=ברכות ב א
otzaria://settings/design
otzaria://tools
otzaria://calendar
otzaria://history
otzaria://bookmarks
otzaria://tool/builtin.calendar
otzaria://book/123?index=5
otzaria://pdf/123?index=12
```

Internally these short aliases are normalized to the canonical `otzaria://open/...` form before dispatch.

## Plugin links

Plugin installation links keep the `plugin` host because they are not screen navigation routes:

```text
otzaria://plugin/install?url=<download-url>&overwrite=true
otzaria://plugin/install-local?path=<absolute-file-path>
```

## Legacy Zayit compatibility

The router also supports a limited legacy mapping:

```text
zayit://book/123
zayit://book/123/line/5
```

These become:

```text
otzaria://open/book/123
otzaria://open/book/123?index=5
```

## Notes for future maintenance

- Keep native iOS code limited to receiving URLs and forwarding them to Dart.
- Add new app actions in `lib/core/external_uri_router.dart` and dispatch them in `MainWindowScreen`.
- Prefer canonical URLs in code and short aliases only for human-facing shortcuts.
- Universal Links (`https://...`) are intentionally not configured here; this branch only implements custom URL schemes that work with sideloaded IPA installs.
