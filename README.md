# Application URL Detection

Qt 6 / C++ desktop application that displays the **foreground application's name, exposed URL and window title** on macOS. Click **Start monitoring**, then switch between apps. Foreground-app activation and supported Accessibility notifications trigger reads, coalesced within 150 ms. A 10-second fallback catches changes that do not emit usable notifications. The most recent 1,000 application/URL/title changes are shown with local timestamps; consecutive identical samples are omitted.

Samples with neither a URL nor a nonblank window title are retried without adding a history row or replacing the last successful activity. Opening the detector's own window does not reset duplicate detection. URL/application changes, non-browser title changes and returning after activity in another application create entries. Browser title updates enrich the latest matching visit instead of creating another row.

Known browsers additionally require a valid full URL before an activity row is recorded. A title-only loading sample is retried rather than logged as a separate visit, preventing an empty-URL row immediately before the completed URL. Other applications can still record title-only activity.

A browser URL with an empty title waits up to 1.5 seconds, retrying every 500 ms, before entering history. This lets a quick redirect and its page title arrive together, while still recording pages that are genuinely untitled. Later title changes for the same application's consecutive URL update the existing row without changing its original detection time. A transient empty title does not erase an already captured title. Distinct URLs are preserved as distinct visits once recorded; redirect targets are not guessed from hostname or scheme similarities.

## Additional browser coverage

The registry in `browserprobe.cpp` separates browser recognition from the URL reader. The nine additional macOS browsers below are installed on the development Mac, and normal/private-window detection has been reported working during manual testing. These implementation routes do not guarantee coverage of every browser version or privacy configuration.

| Browser | macOS implementation / limitation |
| --- | --- |
| Opera | Existing Chromium-style AppleScript route; Accessibility fallback added |
| Opera GX | Chromium-style AppleScript route for `com.operasoftware.OperaGX`, with Accessibility fallback |
| Brave | Existing Chromium-style AppleScript route; Accessibility fallback added |
| Samsung Internet / Samsung Browser | No macOS adapter: the official desktop release is for Windows; mobile detection requires a separate platform integration |
| UC Browser | No verified official macOS build or bundle ID; no guessed adapter added |
| Vivaldi | Existing Chromium-style AppleScript route; Accessibility fallback added |
| Arc | Chromium-style active-tab AppleScript route for `company.thebrowser.Browser`, with Accessibility fallback; vendor availability/account requirements may limit testing |
| DuckDuckGo Browser | Focused document/web-area Accessibility reader for `com.duckduckgo.macos.browser`; no Chrome scripting assumption |
| Tor Browser | Focused document/web-area Accessibility reader for `org.torproject.torbrowser` and the legacy `org.mozilla.tor browser`; requires the browser to expose page metadata |
| Yandex Browser | Chromium-style AppleScript route for `ru.yandex.desktop.yandex-browser`, with Accessibility fallback |
| Chromium | Chromium-style AppleScript route for `org.chromium.Chromium`, with Accessibility fallback |
| Firefox Focus | No macOS desktop adapter: Mozilla lists iOS and Android versions |

Browser Accessibility reads prefer the focused document's outer web area so an embedded frame's address is not selected as the page URL. They use document/web-area metadata rather than typed address-bar text. If the browser does not expose a full URL, the detector retries without inventing a scheme or recording a title-only browser visit. General non-browser apps retain their toolbar-address fallback.

Normal and private windows use the same foreground-window reader. No history files, browser extensions, clipboard operations, remote debugging, or browser privacy-setting changes are used. Correct private-window behavior still needs to be verified on each installed browser; a browser that withholds its page URL cannot be guaranteed to work through Accessibility alone.

Platform and identity references: [Apple's browser identifiers](https://github.com/apple/password-manager-resources/blob/main/quirks/web-browser-extension-distribution-information.json), [Tor Browser's macOS package metadata](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/t/tor-browser.rb), [DuckDuckGo's macOS application source](https://github.com/duckduckgo/apple-browsers/tree/main/macOS), [Samsung desktop availability](https://browser.samsung.com/), [Firefox Focus platforms](https://www.mozilla.org/firefox/browsers/mobile/focus/), [UC Browser official downloads](https://www.ucweb.com/download/pc), [Arc availability](https://resources.arc.net/hc/en-us/articles/19337669022103-Arc-for-Desktop-macOS-and-Windows).

## Applications and permissions

- Safari (including Technology Preview), Chrome (including Beta), Edge, Brave, Opera, Opera GX, Vivaldi, Yandex, Chromium and Arc: existing Automation grants allow the active tab to be read using Apple Events. Without an existing grant, the reader uses Accessibility by default. An unavailable or failed scripting read also tries Accessibility when that permission is already enabled. An empty tab title falls back to the browser's actual front-window title (useful for Vivaldi's internal Speed Dial page), then to matching Accessibility window metadata if available; no page title is invented.
- **Firefox, DuckDuckGo, Tor and general foreground apps:** click **Accessibility settings**, enable UrlDetection in **Privacy & Security → Accessibility** (add the built `.app` using + if needed), click **Retry permissions**, and return to the target app. The reader queries the focused window's title and document URL, and exposed web-area URLs. General apps additionally support recognized toolbar address fields. Browser activity requires a full URL; general apps can record a window title alone. Apps without a focused window or accessibility metadata may provide neither.

The generic reader has a bounded scan (100 elements, 12 levels). Vivaldi uses 300 elements and 24 levels because its browser interface nests website web areas around 20 levels deep; its focused-element ancestor walk allows 32 levels. The reader ignores links, document body text and secure fields rather than collecting unrelated URLs or typed content. A toolbar address field must expose a full URL; missing schemes are never guessed. Custom controls and localized address descriptions may require an app-specific integration.

For Firefox, the reader first requests the application's accessibility role to initialize its page tree, then reads the focused window's web-area URL. This captures the document URL even when the address bar hides the scheme. It requires the same Accessibility permission as other general apps; no Firefox extension or browser preference change is needed. The first sample may contain only a title while Firefox initializes; later notifications, up to two short retries, or the fallback check retry the URL. See Mozilla's [activation implementation](https://raw.githubusercontent.com/mozilla/gecko-dev/master/accessible/mac/Platform.mm) and [web-area URL implementation](https://raw.githubusercontent.com/mozilla/gecko-dev/master/accessible/mac/MOXWebAreaAccessible.mm).

For Opera and Opera GX, the Accessibility reader requests Chromium's `AXEnhancedUserInterface` mode before reading the page. Without that request these browsers can expose a window title and address controls but omit the page web-area URL. Initialization can take a few seconds; notifications, short retries and the fallback check pick up the URL once available. This uses the existing Accessibility grant, without requesting Automation or reading unsubmitted address-bar text. See Chromium's [Accessibility activation documentation](https://www.chromium.org/developers/design-documents/accessibility/).

Run the built `.app` bundle so macOS can identify its permission usage description. During development, macOS may attribute permissions to the launching IDE/terminal; follow the name shown in the system prompt. A stable signed bundle is recommended for distribution and stable permission identity.

**Start monitoring**, **Accessibility settings** and **Retry permissions** request Accessibility access from the visible application using `AXIsProcessTrustedWithOptions`. macOS controls the prompt and access-list entry; this request does not grant access automatically. If the app does not appear (including in the panel called **Device Control and Data Access** on some systems), click **+** and choose the built `UrlDetection.app`. For this workspace the existing build is `build/Qt_6_12_0_Debug/UrlDetection.app`. Open that bundle directly from Finder, enable its switch, return to the app and click **Retry permissions**. Accessibility prompts are requested only by these user actions, not by automatic checks.

**Allow browser Automation permission prompts** is off by default. The reader subprocess checks existing Apple Events read permission for the running process with `AEDeterminePermissionToAutomateTarget(..., false)` before attempting a script. If no grant exists, it takes the Accessibility path without sending that script. To explicitly request Automation when Accessibility cannot expose a browser's URL, enable the checkbox and return to that browser; macOS may then present its normal consent dialog. Uncheck it afterward to restore the default behavior. This avoids unsolicited Automation requests; it does not grant permissions silently or remove the need for Accessibility consent. No promise of complete detection is possible when both permissions are unavailable or the browser withholds metadata.

Vivaldi renders its browser interface in its own extension. The detector excludes that extension's `window.html`/`browser.html` wrapper URLs instead of confusing them with the active website. Live checks of normal and private windows captured the exact website URL, including query and fragment, and the actual window title with Automation prompts disabled. In a live Speed Dial check, the actual window title was exposed as `Start Page - Vivaldi`, but the Accessibility-only path did not expose the actual Speed Dial URL after excluding the interface wrapper. That case requires an existing Automation grant or an explicit permission request; suppressing the dialog cannot also guarantee full metadata for that page.

The macOS **Dock Tile Extension Added** notification for Arc refers to the `DockTilePlugIn.plugin` included in Arc itself. **Data Access Blocked** naming Arc reports Arc's own attempted data access. Neither notification is generated by the detector's URL-reading logic, and this app does not suppress or alter those system notifications. See Apple's [Automation permissions](https://support.apple.com/en-au/guide/mac-help/mchl07817563/mac) and [extension-notification explanation](https://developer.apple.com/videos/play/wwdc2024/10123/?time=1107).

URL reads run in a separate invocation of the same bundled executable. Native notification subscriptions stay in the main application and are removed when monitoring stops; Accessibility IPC during observer setup uses short timeouts and a bounded focused-element ancestor walk. Reads time out after 15 seconds, and errors require an explicit retry instead of repeatedly prompting. No browser extensions, simulated keystrokes, screen recording or JavaScript injection are used.

The bundle starts as an agent to prevent the short-lived reader processes from adding and removing Dock icons. Reader processes use the prohibited activation policy; only the main UI process switches to the regular policy and appears in the Dock.

## Event triggers

- `NSWorkspaceDidActivateApplicationNotification` schedules a read when the foreground app changes.
- `AXObserver` watches supported application/window focus, window creation/destruction, title, layout and selection changes. The focused control's ancestors are watched for page-load changes; focused toolbar text fields and web areas also request value-change notifications. Unsupported subscriptions are tolerated.
- If AppKit reports an invalid process ID (observed with Safari), the observer resolves the exact executable among processes owned by the current user. Ambiguous matches are skipped rather than observing another application.
- Bursts are coalesced within 150 ms. Events arriving during a URL read schedule a follow-up rather than starting overlapping readers.
- An incomplete read gets up to two retries spaced 500 ms apart. Otherwise, the quiet-app fallback runs every 10 seconds, replacing the previous one-second polling loop.
- Observer subscriptions are refreshed for the foreground app/window/focused element before each triggered read. Stop removes native observers and cancels queued checks and retries.

Accessibility notifications are app-dependent and do not guarantee that every URL change emits an event (including same-title navigation and some web-app history updates). Those changes can take up to the fallback interval, plus read time, to appear. This implementation does not require browser extensions.

## Build and check

Requires macOS, Xcode Command Line Tools, CMake 3.19+ and Qt 6.5+ with Widgets.

```sh
cmake -S . -B build/local -DCMAKE_PREFIX_PATH="$(brew --prefix qt)"
cmake --build build/local
open build/local/UrlDetection.app
```

To test manually, start monitoring and visit a URL with a path, query and fragment (for example `https://example.com/?q=test#section`); confirm the exact URL and application name appear promptly after the event (or within the fallback interval where a notification is unsupported). Open a second tab with another site, switch back, then switch browsers. Check that each detected change adds a row, an unchanged page does not repeatedly add rows, and permission denial displays an actionable error. Also switch to a text editor or IDE: confirm the application name, window title and any exposed document URL (possibly `file://`) appear. Switch documents and confirm the title changes, then return to a browser and check its full URL. Test Stop, Clear history and Retry permissions as well. Native accessibility behavior must be checked in a desktop session with Accessibility granted.

Repeat the browser checks in a private/incognito window where the browser offers one, including normal-to-private window switching and tab switching inside the private window. Test the fallback with Automation unavailable and Accessibility enabled. For DuckDuckGo and Tor, specifically confirm that the full scheme, path, query and fragment are exposed; a matching window title alone does not count as URL verification. Keep the same-title/different-URL case open for the 10-second fallback interval before calling it missed.

## Scope

- Captures the **foreground** application and its focused window, not every open window, network request, arbitrary onscreen text or existing browser history. The detector's own window is skipped, leaving the last detection visible.
- macOS cannot supply a URL that an app does not expose. Window titles are displayed as titles, never invented URLs. Generic detection does not promise coverage of every application or custom tab control.
- Preserves URLs supplied by applications, including scheme, path, query and fragment. Document URLs may use `file://` rather than a website address. Unsubmitted address-field content can appear on the generic address-field path; this is not proof of a completed navigation. Redirects and tab changes occurring entirely between reads may be missed. Tabs with identical URL and title are indistinguishable.
- History stays in memory and is cleared on exit. Titles may reveal document names; full URLs may contain sensitive query parameters, and private-window URLs may also be exposed by a browser. Stop monitoring when capture is unwanted.
- Windows and Linux builds show an unsupported-platform message; they need separate browser integrations.

Platform references: [Apple Events usage description](https://developer.apple.com/documentation/bundleresources/protected-resources), [Accessibility attribute reads](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue), [document URL attribute](https://developer.apple.com/documentation/applicationservices/kaxdocumentattribute), [title attribute](https://developer.apple.com/documentation/applicationservices/kaxtitleattribute).
