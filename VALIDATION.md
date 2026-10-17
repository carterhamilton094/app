# Native acceptance checks

These checks need Xcode and, for share targets and Apple Maps, preferably an iPhone. They have not been executed in this Linux workspace.

1. Build an iOS 17+ simulator target. Confirm exactly one `@main` and four tabs: Home, Plan, Heat map, Settings. The manual Xcode workflow only needs updates to the existing three Swift files.
2. In demo mode, Home has date labels and a run-date axis. Run spacing reflects calendar dates. Feed maps remain illustrative; no demo GPX/navigation action is offered. No backend field or top-right settings button is visible.
3. After updating Render, reconnect Strava. The health page should show Strava configured. Real mapped runs replace demo data. Private or virtual runs with no geometry show a clear empty state.
4. Set home/radius in Settings. With no GraphHopper key, history and heat map remain usable and alternatives show unavailable. With a valid key, refresh in Settings and generate routes. Open one from Home or Plan and confirm its distance/climbing and route line agree. Tap the map, title and View route label of each feed tile; all should open the same detail screen as Plan. For a flat historical run where only hillier candidates are found, confirm no strict match is claimed. Reveal Show closest options, check real map geometry and the elevation difference, then open the option and confirm the warning persists. Hiding the options restores strict matching. Out-of-radius or distance-mismatched paths must never appear as closest options.
5. Heat map: load older history, including a batch that has only rides; the next page still advances. Toggle history and discoveries independently. Repeated runs increase density. New discovered routes appear as dashed green lines, not completed-run density.
6. Close/reopen the app. Reconnect the same athlete if necessary; discoveries remain. Connect a different athlete and verify no other account's saved routes, completion links or history appear.
7. Open a real route. Share the GPX through the native sheet and save another copy to Files. Import into a compatible GPX app/viewer; inspect point order, elevation, start/end and XML title. Confirm the file is a planned track with no fabricated timestamps.
8. Apple Maps: Directions to start opens walking directions to the first point. It must not promise the generated loop will be followed.
9. Link a saved route to a completed Strava run. With read-only authorization, adding a note requires a trip to Settings and new write permission. Cancel authorization and confirm ordinary read-only sync still works.
10. Grant write permission. Preview/cancel the note confirmation and verify no Strava description changed. Confirm once on a chosen test activity. Existing description must remain, with one “Explored a new loop with Runways.” line appended. Repeat and verify no duplication. Another athlete's run cannot be changed.
11. No description changes occur merely by syncing, discovering, exporting, sharing or linking. The app does not claim to record/upload activities or automatically detect route completion.

## Automated tests

- Backend: `cd server && npm test` (Node 22+). Mocked upstream services; no external credentials.
- Native: generate the project with XcodeGen, select the Runways scheme and a simulator, then Command-U. Tests cover GPX validity and coordinate ordering, no-map export rejection, density counts vs GPS samples, no interpolation across long gaps, and per-athlete library persistence. For a manually created Xcode project, add a unit-test target and adapt `@testable import Runways` to your app's product module name.
