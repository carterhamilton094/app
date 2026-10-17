# Runways

A native iOS 17+ SwiftUI running app. Connect Strava, see training trends, and discover routes near home with a similar distance and climb.

## Current app

- **Home:** distance trend with a real calendar x-axis and date labels, followed by Strava run cards with maps, distance, climbing, pace and two alternative slots.
- **Plan:** choose workout distance and climbing. Open a discovered route to inspect, export or share it.
- **Heat map:** completed Strava run density (yellow → orange → red), with discovered routes shown separately as dashed green lines. Discoveries are saved on the phone per Strava athlete. Use **Load older Strava history** to import earlier activity batches. Private/unmapped activities have no density geometry. Up to 5,000 highest-use approximate 150 m grid cells are shown. A cell counts distinct runs, not the number of GPS samples. Discovered routes are not counted as completed runs.
- **Settings:** Strava connection, optional activity-note permission, home selection, radius and routing availability. The backend address is configured in code; runners do not enter a server URL. Distance/climbing controls remain in Plan, while home/radius controls live in Settings.

Demo runs and geometry are clearly marked illustrative. Demo routes cannot be exported or used for navigation. No routes are fabricated when real matching fails.

## Update your existing Xcode project (no Homebrew needed)

1. Download the latest GitHub ZIP and unzip it.
2. Replace the **contents** of your existing `Models.swift`, `API.swift`, and `RunwaysApp.swift` with the matching files from the downloaded `Runways` folder. Do not add duplicates.
3. Keep exactly one `@main`: the one on `RunwaysApp`. Remove the old starter `MyApp.swift` from the target if it still refers to `ContentView`.
4. Use an iOS 17+ deployment target. Under **Target → Info → URL Types**, register the URL scheme `runways`.
5. Press Command-R. There should be four bottom tabs: Home, Plan, Heat map, Settings.
6. The backend must also be updated/redeployed before this app version can sync. Reconnect Strava under Settings after the backend restarts; current server sessions are stored in memory.

The app currently points to `https://runways.onrender.com` in `RunwaysApp.swift`. App icons are configured separately in your local Xcode asset catalog. `previews/runways-icon.png` is the generated icon artwork; resize to 1024 × 1024 before adding it to AppIcon. The older preview PNGs show the original browser mockup, not the current native tab layout.

## Generate an Xcode project (optional)

On a Mac with Xcode 15+ and XcodeGen installed, run `xcodegen generate` at the repository root and open `Runways.xcodeproj`. Select your signing team and a unique bundle identifier. This also creates a `RunwaysTests` target. Choose an installed iOS simulator and use Command-U to run those tests. XcodeGen is a development convenience and has no effect on App Store eligibility.

This Linux workspace has no Apple SDK or Xcode. Swift syntax can be parsed here; native type checking, simulator rendering, GPX sharing and Apple Maps handoff still require validation on a Mac/device. See [VALIDATION.md](VALIDATION.md).

## Backend and Render

Node.js 22+, no third-party dependencies. On Render use:

| Setting | Value |
|---|---|
| Service type | Web Service |
| Branch | `main` |
| Root directory | `server` |
| Build command | `npm install` |
| Start command | `node index.js` |
| Health check | `/health` |

Set environment variables in Render; never commit credentials or paste them into chat:

- `NODE_VERSION=22`
- `STRAVA_CLIENT_ID`: your Strava API application ID.
- `STRAVA_CLIENT_SECRET`: the current secret for that application.
- `PUBLIC_URL=https://runways.onrender.com` for this deployment.
- `GRAPHHOPPER_KEY`: a GraphHopper Directions API key supporting foot routing, elevation and round-trip routing. This is required to discover new routes, but not to sync Strava history or show its heat map. Sign up at https://www.graphhopper.com/ and enter the key directly in Render. Save and redeploy. Check `/health` reports `routingConfigured:true`, then refresh Strava in Settings so the app sees the updated capability. The backend uses flexible mode (`ch.disable=true`) for round trips and requests unencoded coordinates with elevation. A nonempty key is only a configuration check; actual provider validity/quota is established by generating routes.

Strava **Authorization Callback Domain** must be `runways.onrender.com` (hostname only). The backend callback is `/auth/callback` and returns to the app's `runways` scheme. Initial connection requests `read,activity:read_all`. Optional note permission requests an additional `activity:write` with a fresh authorization screen. Declining write access leaves read-only use available.

For local backend development:

```sh
cd server
cp .env.example .env
# Enter credentials privately in ignored .env.
npm start
```

For hosts that inject variables, use `node index.js`. Always use HTTPS for the deployed phone backend. Strava requests use www.strava.com; route requests use graphhopper.com; the native maps use Apple MapKit. Review provider terms, Strava branding and quotas before public distribution.

## Export, sharing and navigation

Open a real alternative from Home, Plan or Heat map:

- **Share route** opens the standard iPhone share sheet with a GPX attachment (AirDrop, Messages, Files and compatible installed apps).
- **Save GPX to Files** exports the full planned track, including elevation when available. Coordinates are longitude/latitude internally and latitude/longitude attributes in GPX 1.1. No timestamps or fabricated activity recording are included.
- **Directions to start in Apple Maps** opens walking directions to the first route point. Apple Maps calculates its own path; this does not navigate the entire generated loop.

GPX imports depend on the recipient app. Creating a Strava route from a file may require the Strava website and suitable account features; this app does not directly create Strava routes. It does not provide turn-by-turn navigation. Route files include location details, so review them before sharing.

## Completed runs and the optional Strava note

Runways does not record GPS runs, upload activities or automatically detect that a generated route was completed. Record using Strava or a watch, refresh Home, open the saved discovery and choose **Link completed Strava run**. Linking is your own association, not a GPS completion verification.

If desired, enable **Strava activity notes** in Settings, grant write access, and choose **Add optional note on Strava** from the linked route. A confirmation precedes each change. This appends:

> Explored a new loop with Runways.

The text is added to the activity **description**, not a comment. The server fetches the current description, preserves it, verifies ownership and running sport, and avoids adding the note twice. No note is posted just by discovering, exporting, sharing or linking a route. Automated notes on future uploads require a recording/upload workflow and are not implemented.

## Matching and storage

Home requests four candidate loops for each visible run and returns up to two; Plan requests six and returns up to four. Returned vertices must remain inside the chosen radius. Routes start near home and close within 200 m. Distance must be within 20% of target; ascent within the larger of 40 m or 35% of target. Similarity weights distance error at 70% and climbing error at 30%, with a 30 m floor for flat targets. Duplicates and candidates mostly retracing the original recorded run are filtered. This is a heuristic, not a physiological prediction or guarantee of novelty. Surface, access, crossings, weather and gradient distribution need human review.

Automatic matching supports runs of 2–30 km and up to 800 m climbing. Zero or one match is possible. Per-athlete feed searches are cached for ten minutes, capped at twelve new searches in ten minutes, and limited to three in flight. Plan requests have a one-minute cooldown. Recent activities are cached for five minutes. Older history loads in batches of up to 100 activities, including non-running activities when advancing pagination.

Strava tokens stay on the backend; the device stores its opaque session in Keychain. Home and route radius are stored locally. Discoveries and completion links are stored locally per athlete and remain available after reconnecting the same account; they are not a cross-device backup. Completed history is reloaded from Strava. Disconnect revokes Strava access and clears visible account data but retains that account's local saved-route library.

## Validation and release limitations

Routing errors distinguish missing configuration, provider authentication/access failures, quota exhaustion, timeouts, unavailable services, unsupported requests and incomplete elevation/geometry. Provider messages and key-bearing URLs are never returned to the phone. If a seed has no routable point, later candidates are still attempted; an area with no suitable routes returns an empty match list.

Run `cd server && npm test`. These tests use mocked providers and real local HTTP to exercise authentication, maps, matching, history pagination, write permission, activity ownership, note preservation and idempotency. They do not use real credentials or modify live Strava activities.

Native tests in `RunwaysTests` cover GPX XML, invalid/unmapped geometry, heat-grid counting and per-athlete saved-route isolation. They require Xcode and have not been executed in this Linux workspace.

Backend tokens and sessions currently live in memory: a restart/redeploy requires reconnecting Strava. Before release, add encrypted persistent token/session storage, account deletion, production abuse controls, monitoring without sensitive URLs, and privacy/terms arrangements. There is no background sync/webhook service, GPS recorder, activity upload, direct Strava route creation or native turn-by-turn navigation yet. A GitHub push is not proof of a successful Render deployment, successful live provider requests, or App Store readiness.
