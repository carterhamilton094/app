# Routing cost and open-source options

Reviewed against official project sources on 17 October 2026. This is a technical comparison, not a deployment benchmark or verified hosting-price quotation. GraphHopper Cloud remains the active provider. No accounts have been created, servers purchased, public demo endpoints used or paid routing requests made for this review.

## Reduce demand before changing providers

Runways now checks the existing per-athlete, on-device route library against distance, climbing, start location, closure and radius. Home does not generate routes merely because a card appears. Users request fresh options explicitly. Plan checks saved routes first and offers a separate fresh-search button.

A fresh search is capped at two provider HTTP requests instead of six, with early completion if one response already has two suitable distinct routes. That is a 67% reduction in the maximum HTTP requests for an uncached search; it is not a measured 67% reduction in total billable credits. Credit charging can depend on waypoints and provider features. Fewer candidates can mean fewer matches, particularly for flat targets in hilly areas.

Successful paths and no-path responses are cached per athlete session for one hour and reused by feed and Plan. Concurrent identical requests share a pending response. Different effort/radius/novelty constraints are checked again before results are accepted. No API key is included in the cache key. Server caches disappear on restart. The existing device library survives app relaunches but not app deletion, and is not a cross-device backup. Provider retention/export terms still need reviewing before public release.

The app does not yet enforce a global daily credits budget or report provider billable credits. Per-search HTTP caps and per-session limits are not a full production billing control; provider account quotas remain relevant.

## Engine comparison

| Engine | Strengths for Runways | Weaknesses / extra work | Assessment |
|---|---|---|---|
| Self-hosted GraphHopper | Closest fit to our current request/response adapter. Native round-trip algorithm, walking profiles and configurable elevation support. Apache 2.0 engine license. Our own instance can enable flexible routing without the hosted service's account entitlement. | Operate the JVM service, import map extracts, obtain elevation, update graphs, secure the endpoint and manage capacity. Open-source and hosted APIs are not guaranteed identical; test a pinned release. Native loop generation still does not guarantee target ascent or a safe/enjoyable route. | Best first technical proof of concept because it minimises adaptation. |
| Self-hosted openrouteservice | Documented round-trip parameters (`length`, `points`, `seed`), walking profiles, elevation support and route metadata such as surface and steepness. Official Docker deployment guidance. | Java service with graph import, elevation and memory/storage requirements. New response adapter and tuning needed. GPLv3 obligations need assessment for engine changes/distribution; a separate backend does not automatically make the Swift app GPL. Hosted API quotas/terms are separate from self-hosting. | Strong second candidate, particularly if surface/steepness metadata becomes a priority. |
| Self-hosted Valhalla | MIT license, pedestrian routing and configurable hill preference; tiled regional data, elevation sampling, map matching and multimodal features. Official Docker images. | New API/geometry adapter and consistent ascent calculation needed. We must validate an appropriate loop-search strategy; tour optimisation is not the same as finding a workout-length running loop. Operational setup is more involved than reusing our current GraphHopper adapter. | Attractive longer-term candidate for walking preferences and regional routing. |
| Self-hosted OSRM | Fast routing with official Docker images and a permissive BSD 2-clause license. Supports custom Lua profiles and regional extracts. | Less directly aligned with this app's climbing and workout-loop requirements. Would need an elevation pipeline, matching logic and loop strategy; routing profiles require preprocessing. Default public examples are driving-oriented. | Lower priority for this running/elevation use case. |

An engine's license is separate from OpenStreetMap's ODbL/attribution requirements and the license/availability of elevation datasets. Public demonstration servers are not a production hosting plan. Open-source software removes a commercial API request allowance, but not compute, storage, data-download, backup and maintenance costs. Larger geographical coverage increases import and operational burden. Running a routing engine inside the iPhone app is a separate offline product effort, not the proposed next step.

## Recommended next step, before any provider migration

Keep the efficient hosted implementation while collecting results from explicit searches. For a future proof of concept, start with self-hosted GraphHopper and a small Queensland/coastal region relevant to the tester, then compare openrouteservice using the same map area and elevation source. Use pinned stable versions rather than whatever the development branch requires.

Prepare a fixed set of workout/start/radius cases: flat coastal runs, hilly suburban runs, 3/5/8/12 km targets, narrow radii, and private/unmapped starts. Compare:

- proportion of cases producing at least one valid loop within the two-request budget;
- actual distance, climbing error, home-radius containment and retraced sections;
- path/road/surface quality by manual review, not just map appearance;
- response time, import/rebuild duration, RAM, disk and data-update effort;
- equivalent measured monthly hosting cost versus observed hosted-provider credit use.

Only choose an instance size or migrate after measuring that workload. The next proof of concept would require a deployment target and data preparation; none was started during this review. No engine can infer all access restrictions or current safety conditions from map data alone.

## Official sources inspected

- [GraphHopper engine and license](https://github.com/graphhopper/graphhopper), [web API round-trip parameters](https://github.com/graphhopper/graphhopper/blob/master/docs/web/api-doc.md), [elevation configuration](https://github.com/graphhopper/graphhopper/blob/master/docs/core/elevation.md), [Apache 2.0 license](https://github.com/graphhopper/graphhopper/blob/master/LICENSE.txt).
- [openrouteservice engine and Docker guidance](https://github.com/GIScience/openrouteservice), [round-trip options](https://github.com/GIScience/openrouteservice/blob/main/docs/api-reference/endpoints/directions/routing-options.md), [surface/steepness metadata](https://github.com/GIScience/openrouteservice/blob/main/docs/api-reference/endpoints/directions/extra-info/index.md), [GPLv3 license](https://github.com/GIScience/openrouteservice/blob/main/LICENSE).
- [Valhalla capabilities and deployment](https://github.com/valhalla/valhalla), [pedestrian costing/hill preference implementation](https://github.com/valhalla/valhalla/blob/master/src/sif/pedestriancost.cc), [MIT license](https://github.com/valhalla/valhalla/blob/master/COPYING).
- [OSRM backend and deployment](https://github.com/Project-OSRM/osrm-backend), [BSD license](https://github.com/Project-OSRM/osrm-backend/blob/master/LICENSE.TXT).

Hosted prices, current credit allowances and commercial account eligibility have not been independently verified in this review. They must be checked against the relevant provider's current terms before purchase or migration.
