# Runways

A native iOS 17+ SwiftUI running app: connect Strava, review recent distance history, choose a workout's distance and climbing, and discover alternative loops within a radius of home.

## Run on iOS

Requires a Mac with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. In this directory run `xcodegen generate`.
2. Open `Runways.xcodeproj`, select the Runways target, and choose your development signing team and a unique bundle identifier.
3. Run on an iOS 17+ simulator or device.
4. Open Connections in the app and enter your deployed HTTPS backend URL, then connect Strava. History uses clearly marked demo data until connected. Tap a recent run to adopt its targets.
5. Choose home on the map (the initial Brisbane location is an example), set your containment radius, and find routes.

Generated Xcode projects and Info.plist are intentionally ignored. XcodeGen creates them from project.yml. This Linux workspace cannot compile or launch the iOS app; the native build remains unverified.

## Backend

Node.js 22+, no third-party dependencies:

```sh
cd /workspace/app/server
cp .env.example .env
# Set values securely in .env or deployment environment; do not commit .env.
npm start
```

For deployments that inject variables directly, use `node index.js` instead. Deploy behind HTTPS; do not expose a plaintext backend to phones. In the app enter the deployment URL. Server readiness: `GET /health`; configuration flags must be true for live integrations.

Create a Strava API application and configure its authorization callback domain to your backend hostname. Set `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`, and `PUBLIC_URL` (the backend HTTPS origin, no path). The callback endpoint is `/auth/callback`; the backend redirects to the app's `runways` URL scheme. Activity read permission is required. Strava application access limits and approval requirements still apply.

Set `GRAPHHOPPER_KEY` to a GraphHopper Directions API key with foot routing, round-trip routing and elevation support. Requests use graphhopper.com; Strava authentication and activity requests use www.strava.com. Apple MapKit provides the map. Provider terms, attribution, quotas and Strava branding requirements must be reviewed before public distribution.

`npm test` exercises geographic containment, loop closure, deduplication, effort filtering, input validation and matching. Run from `server`.

## Matching and data

The backend requests six walking/running loop candidates from GraphHopper. All returned geometry vertices must remain inside the home radius; the route must start near home and close within 200 m. Candidates must be within 20% of target distance and within the greater of 40 m or 35% of target climbing. Duplicate geometry is removed and the best four candidates are returned. Similarity weights relative distance error at 70% and ascent error at 30%, with a 30 m denominator floor for flat routes. This is a heuristic, not a physiological prediction. Surface, gradient distribution, weather, access restrictions and technical terrain are not modeled. Inspect any route before using it.

The history chart shows distances for runs among the latest 100 Strava activities; it is not a full-history training analysis or an imported training plan. Targets can be entered manually or copied from a recent run. No routes are fabricated when a provider returns no suitable match.

Strava client secrets and access/refresh tokens remain on the backend. The device stores its backend session in Keychain and the selected home coordinates in local preferences. Home coordinates are sent to the backend and GraphHopper only when generating routes. Disconnect revokes Strava authorization and clears the local session.

## Prototype limitations and release work

Backend tokens and sessions currently live in memory and disappear on restart. Before production use, add encrypted persistent storage, per-athlete refresh serialization, account deletion, appropriate abuse controls on public authentication endpoints, observability without sensitive URLs, and a privacy policy. Route requests have a per-session one-minute cooldown. Deploy one server instance for this prototype. Health, tests and unauthenticated errors can be verified without credentials; OAuth and live route generation require real provider configuration and remain unverified here. No background sync, turn-by-turn navigation, GPX export, HealthKit integration or training-plan provider is included.
