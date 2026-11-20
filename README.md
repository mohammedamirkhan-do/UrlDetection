# Application URL Detection

Qt 6 / C++ desktop application that displays the **foreground application's name, exposed URL and window title** on macOS. Click **Start monitoring**, then switch between apps. Foreground-app activation and supported Accessibility notifications trigger reads, coalesced within 150 ms. A 10-second fallback catches changes that do not emit usable notifications. The most recent 1,000 application/URL/title changes are shown with local timestamps; consecutive identical samples are omitted.

Samples with neither a URL nor a nonblank window title are retried without adding a history row or replacing the last successful activity. Opening the detector's own window does not reset duplicate detection. URL/application changes, non-browser title changes and returning after activity in another application create entries. Browser title updates enrich the latest matching visit instead of creating another row.

Known browsers additionally require a valid full URL before an activity row is recorded. A title-only loading sample is retried rather than logged as a separate visit, preventing an empty-URL row immediately before the completed URL. Other applications can still record title-only activity.

A browser URL with an empty title waits up to 1.5 seconds, retrying every 500 ms, before entering history. This lets a quick redirect and its page title arrive together, while still recording pages that are genuinely untitled. Later title changes for the same application's consecutive URL update the existing row without changing its original detection time. A transient empty title does not erase an already captured title. Distinct URLs are preserved as distinct visits once recorded; redirect targets are not guessed from hostname or scheme similarities.

## Project structure and responsiveness

```text
src/
  app/                 # Entry point, worker modes and main window
  modules/
    detection/         # Browser registry, URL metadata and event supervision
    blocking/          # Config/policy, block-list controls and tab-close scripts
  platform/mac/        # Shared AppKit/Accessibility/Apple Events adapters
resources/macos/       # Application bundle metadata
config/                # Editable domain list, also bundled as a default
```

The two feature modules share the macOS adapter because reading and closing must use the same browser identity, focused window and URL checks. Platform code is kept out of the domain-policy parser and UI. The source tree is grouped in Qt Creator by CMake; open the root `CMakeLists.txt` as before. Config paths and the bundled executable name are unchanged.

The GUI uses one persistent `--watch-activity` process for native observation and at most one short-lived `--read-browser-url` process for reading/closing. This keeps native Accessibility IPC and AppleScript work outside the UI event loop without moving AppKit calls onto arbitrary threads. The observer runs its own native event loop in accessory mode, with no window or Dock tile. Changes are coalesced at 150 ms; the GUI retains its 10-second fallback. A five-second health heartbeat is process supervision, not browser URL polling.

Observer crashes restart automatically with a capped backoff. If no valid observer heartbeat/event arrives for 15 seconds, the five-second watchdog check kills and restarts that worker; the fallback still requests reads while it is unavailable. A read has a 15-second timeout. Transient startup failures, crashes and timeouts get up to two short retries and later event/fallback retries instead of permanently blocking that browser. Permission errors still require explicit permission correction/retry. Stop monitoring cancels queued retries and stops the observer and current read. The observer also quits when its output pipe closes, so a GUI crash does not leave a permanent orphan observer. History remains bounded to 1,000 rows and policies to 1,000 domains.

This is resilience for a running desktop application, not a system daemon or an always-on network filter. Detection and tab closing are implemented for macOS; Windows/Linux need their own adapters. The default macOS deployment target is 14.4 (matching the Qt runtime used here); an explicit CMake setting or `MACOSX_DEPLOYMENT_TARGET` environment value is respected. Qt and every bundled dependency must also support the chosen target. Distribution still needs Qt deployment, a compatible CPU/build target and normal macOS permission/signing handling. No claim of support for every OS or Mac configuration is made.

## Website blocking by closing browser tabs

Website blocking uses the browser-tab-closing approach rather than a hosts-file change or Network Extension. It needs no administrator password or Apple Developer signing. It reacts to detected browser navigation: it does not stop the initial network request, and a page may begin loading before the tab closes.

1. Click **Open website block list** and edit `config/blocked-websites.json`. Development builds use the project file; installed copies get a writable default under `QStandardPaths::AppConfigLocation`. The button tooltip shows the active path. The config is a simple JSON array: `["chatgpt.com", "deepseek.com"]`. List each base domain once, without URL schemes, paths or wildcards. All its subdomains are covered automatically. The earlier versioned `websites` object is still accepted for existing installations.
2. Enable **Close blocked website tabs while monitoring**, then click **Start monitoring**. The checkbox is off on every fresh launch. Each valid detected HTTP/HTTPS URL is matched by hostname, including subdomains. `chatgpt.com` matches `chatgpt.com` and `sub.chatgpt.com`, but not `notchatgpt.com`, `chatgpt.com.example.org`, a username or a query-string mention. Unicode domains are normalized to ASCII. Separate domains such as `chat.openai.com` are not subdomains of `chatgpt.com` and require their own entry; brand ownership is not inferred.
3. The reader subprocess rechecks the foreground browser, focused window and exact URL before closing. It uses selected-tab close controls, or native Close Tab menu items for Safari, UC, Yandex, Opera, Opera GX and Vivaldi. Arc uses its native Archive Tab menu action, including Little Arc windows. Safari changes Command-W to Close Window when only one tab remains; that menu action is allowed only when Close Tab is disabled and the unmodified Command-W item identifies the last-tab case. Window traffic-light buttons and injected keystrokes are never used. If no suitable control is exposed, Safari/Chromium-family browsers can fall back to a guarded AppleScript that rechecks the active tab URL.
4. Accessibility is required for the control-based route. Existing browser Automation grants are reused for AppleScript. To request a missing browser grant, enable **Allow browser Automation permission prompts** and return to the browser. This is macOS browser-control consent, not an administrator password prompt. Firefox/Tor/DuckDuckGo rely on exposed tab controls rather than assuming Chromium scripting. A missing permission or unsupported control is displayed; it is never reported as a successful close.
5. Saved JSON changes reload automatically and request a new foreground check. Invalid edits retain the last valid policy and show an error. An empty domain array (`[]`), unchecking the checkbox, stopping monitoring or closing the app stops new close requests. Existing browser tabs are not reopened automatically.

Only the detected active tab in the foreground browser is targeted; this does not scan or close every background tab as EmpMonitor's periodic scripting loop does. Existing application/focus/Accessibility events trigger reads, with the existing 10-second fallback for unsupported events. Closing is attempted before the normal history/title-settling logic. The UI reports a close request; a browser's own unsaved-data dialog can still prevent completion. Switching tabs during a request can cause it to be skipped. Unexposed URLs or unsupported close controls cannot be enforced. Apps with custom/vertical tabs, localized controls, private-window variants and browser updates require live verification; do not assume universal browser coverage.

Yandex can leave an empty window with a stale web-area URL after its last tab closes. The Accessibility reader now requires a selected browser tab before accepting that document URL, preventing repeated close requests against the stale page.

No privileged helper, hosts/DNS modification, certificate installation or network interception is used. There is no system-wide enforcement after the app exits.

If the earlier hosts-file version was already applied, its saved system entries remain until its `BEGIN/END UrlDetection website blocks` section is removed from `/etc/hosts` once with administrator approval. Switching to tab closing does not silently undo protected system settings. Remove that old section before testing tab-only behavior; preserve unrelated hosts entries.

## Additional browser coverage

The registry in `src/modules/detection/browserprobe.cpp` separates browser recognition from the URL reader. The nine additional macOS browsers below are installed on the development Mac, and normal/private-window detection has been reported working during manual testing. These implementation routes do not guarantee coverage of every browser version or privacy configuration.

| Browser | macOS implementation / limitation |
| --- | --- |
| Opera | Existing Chromium-style AppleScript route; Accessibility fallback added |
| Opera GX | Chromium-style AppleScript route for `com.operasoftware.OperaGX`, with Accessibility fallback |
| Brave | Existing Chromium-style AppleScript route; Accessibility fallback added |
| Samsung Internet / Samsung Browser | No macOS adapter: the official desktop release is for Windows; mobile detection requires a separate platform integration |
| UC Browser | Installed `UC.app` verified as `org.uc.UC`; Chromium-style reader and native Close Tab menu support. Package provenance is not independently verified. |
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

URL reads and tab closing run in a short-lived invocation of the same bundled executable. Native notification subscriptions live in the supervised observer process and stop when monitoring stops; Accessibility IPC during observer setup uses short timeouts and a bounded focused-element ancestor walk. Reads time out after 15 seconds; transient failures retry automatically, while permission errors require an explicit retry instead of repeatedly prompting. No browser extensions, simulated keystrokes, screen recording or JavaScript injection are used.

The bundle starts as an agent to prevent the short-lived reader processes from adding and removing Dock icons. Reader processes use the prohibited activation policy; only the main UI process switches to the regular policy and appears in the Dock.

## Event triggers

- `NSWorkspaceDidActivateApplicationNotification` schedules a read when the foreground app changes.
- `AXObserver` watches supported application/window focus, window creation/destruction, title, layout and selection changes. The focused control's ancestors are watched for page-load changes; focused toolbar text fields and web areas also request value-change notifications. Unsupported subscriptions are tolerated.
- If AppKit reports an invalid process ID (observed with Safari), the observer resolves the exact executable among processes owned by the current user. Ambiguous matches are skipped rather than observing another application.
- Bursts are coalesced within 150 ms. Events arriving during a URL read schedule a follow-up rather than starting overlapping readers.
- An incomplete read gets up to two retries spaced 500 ms apart. Otherwise, the quiet-app fallback runs every 10 seconds, replacing the previous one-second polling loop.
- The background observer refreshes subscriptions for its foreground app/window/focused element on native notifications, independently of read completion. Stop kills that observer (macOS releases its subscriptions) and cancels queued checks and retries.

Accessibility notifications are app-dependent and do not guarantee that every URL change emits an event (including same-title navigation and some web-app history updates). Those changes can take up to the fallback interval, plus read time, to appear. This implementation does not require browser extensions.

## Build and check

Requires macOS, Xcode Command Line Tools, CMake 3.19+ and Qt 6.5+ with Widgets.

```sh
cmake -S . -B build/local -DCMAKE_PREFIX_PATH="$(brew --prefix qt)"
cmake --build build/local
open build/local/UrlDetection.app
```

To produce a bundle with Qt runtime libraries included:

```sh
cmake --install build/local --prefix "$PWD/build/package"
```

Use a fresh staging directory for each package. On macOS with Qt 6.7+, CMake installs only the Cocoa platform and native-style plugins required by this Widgets app, then asks `macdeployqt` to deploy their dependencies. This avoids copying unrelated PDF/QML/virtual-keyboard plugins from a shared Qt installation. The resulting `build/package/UrlDetection.app` is a development bundle for the architecture and macOS deployment target used to build it, not a notarized universal distribution. Test on the target Mac and grant Accessibility/Automation as required; Qt deployment does not grant permissions or bypass Gatekeeper.

On the current development machine, some transitive Homebrew libraries in the staged bundle advertise macOS 27.2 as their minimum even though the app and Qt frameworks target 14.4. The staged bundle is therefore a local test build, not a verified macOS 14.4 release. Use a consistent Qt/dependency SDK built for the intended minimum OS before distributing to older Macs; lowering the app's deployment target alone does not rebuild those dependencies. The current build is `arm64`; Intel/universal builds need matching Qt libraries and separate validation.

To test manually, start monitoring and visit a URL with a path, query and fragment (for example `https://example.com/?q=test#section`); confirm the exact URL and application name appear promptly after the event (or within the fallback interval where a notification is unsupported). Open a second tab with another site, switch back, then switch browsers. Check that each detected change adds a row, an unchanged page does not repeatedly add rows, and permission denial displays an actionable error. Also switch to a text editor or IDE: confirm the application name, window title and any exposed document URL (possibly `file://`) appear. Switch documents and confirm the title changes, then return to a browser and check its full URL. Test Stop, Clear history and Retry permissions as well. Native accessibility behavior must be checked in a desktop session with Accessibility granted.

Repeat the browser checks in a private/incognito window where the browser offers one, including normal-to-private window switching and tab switching inside the private window. Test the fallback with Automation unavailable and Accessibility enabled. For DuckDuckGo and Tor, specifically confirm that the full scheme, path, query and fragment are exposed; a matching window title alone does not count as URL verification. Keep the same-title/different-URL case open for the 10-second fallback interval before calling it missed.

## Scope

- Captures the **foreground** application and its focused window, not every open window, network request, arbitrary onscreen text or existing browser history. The detector's own window is skipped, leaving the last detection visible.
- macOS cannot supply a URL that an app does not expose. Window titles are displayed as titles, never invented URLs. Generic detection does not promise coverage of every application or custom tab control.
- Preserves URLs supplied by applications, including scheme, path, query and fragment. Document URLs may use `file://` rather than a website address. Unsubmitted address-field content can appear on the generic address-field path; this is not proof of a completed navigation. Redirects and tab changes occurring entirely between reads may be missed. Tabs with identical URL and title are indistinguishable.
- History stays in memory and is cleared on exit. Titles may reveal document names; full URLs may contain sensitive query parameters, and private-window URLs may also be exposed by a browser. Stop monitoring when capture is unwanted.
- Windows and Linux builds show an unsupported-platform message; they need separate browser integrations.

Platform references: [Apple Events usage description](https://developer.apple.com/documentation/bundleresources/protected-resources), [Accessibility attribute reads](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue), [document URL attribute](https://developer.apple.com/documentation/applicationservices/kaxdocumentattribute), [title attribute](https://developer.apple.com/documentation/applicationservices/kaxtitleattribute).
