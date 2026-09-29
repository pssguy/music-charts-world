# Weekly deployment investigation — 2026-09-29

## Evidence and limits

The detailed log for [run 36204426173](https://github.com/pssguy/music-charts-world/actions/runs/36204426173)
records worldwide period **2026-09-24**, **55 structurally successful national
markets**, no failed or unavailable market names, and one critical error:
“Chart periods do not match the verified worldwide chart period.” The freshness
gate and all render jobs were skipped. The missing publication-decision upload
warning is a consequence of that skipped gate, not the cause.

The report upload succeeded at the time, but its retention was one day. On
2026-09-29 the run's artifact API returned `total_count: 0` and `gh run download`
returned “no valid artifacts found to download.” Its report cannot now be
inspected. The retained logs do not name the mismatched market; do not treat
today's source state as proof of every historical market period.

A read-only fetch of all 56 sources on 2026-09-29 found that
[India's weekly source](https://kworb.net/spotify/country/in_weekly.html) still
declares **2026-08-20**. The worldwide page and all other 54 national pages
declare **2026-09-24**. All passed the existing structural validation. This is
a valid but frozen source publication, not HTTP unavailability or a parser
failure. Its date matches the last successful release, making it a strong
explanation for the recurring mismatches, with the historical limitation above.

## Run comparison

Dates below are UTC. Logs were downloaded and compared, including the summary
step's exported validation counts and publication decisions.

| Runs | Result and actual stopping point |
|---|---|
| [Aug 7](https://github.com/pssguy/music-charts-world/actions/runs/31207690310), [Aug 14](https://github.com/pssguy/music-charts-world/actions/runs/31829521489), [Aug 21](https://github.com/pssguy/music-charts-world/actions/runs/32512705478) | 55 structurally valid markets; freshness gate rejected the previous week's source (`stale-source`). |
| [Aug 8](https://github.com/pssguy/music-charts-world/actions/runs/31272708165), [Aug 15](https://github.com/pssguy/music-charts-world/actions/runs/31901592221) | Successful Saturday deployments, current periods August 6 and August 13. |
| [Aug 22](https://github.com/pssguy/music-charts-world/actions/runs/32591260219), [Aug 26 manual](https://github.com/pssguy/music-charts-world/actions/runs/33007755270) | Fetch and freshness passed for August 20. Rendering stopped on runner shutdown/cancellation signals. These logs alone do not establish an OOM cause. |
| [Aug 27 manual](https://github.com/pssguy/music-charts-world/actions/runs/33036924302) | Successful deployment of August 20 on commit `53546cd`, with the existing render-recovery changes. |
| [Aug 29 first](https://github.com/pssguy/music-charts-world/actions/runs/33231432638), [Aug 29 second](https://github.com/pssguy/music-charts-world/actions/runs/33274284897) | 55 structurally valid markets; mixed periods, worldwide August 27. |
| [Sep 4](https://github.com/pssguy/music-charts-world/actions/runs/33930259814), [Sep 5](https://github.com/pssguy/music-charts-world/actions/runs/33989257436) | Same mixed-period failure, worldwide September 3. |
| [Sep 11](https://github.com/pssguy/music-charts-world/actions/runs/34659455445), [Sep 12](https://github.com/pssguy/music-charts-world/actions/runs/34716957279) | Same mixed-period failure, worldwide September 10. |
| [Sep 18](https://github.com/pssguy/music-charts-world/actions/runs/35407122132), [Sep 19](https://github.com/pssguy/music-charts-world/actions/runs/35467140470) | Same mixed-period failure, worldwide September 17. |
| [Sep 26 first](https://github.com/pssguy/music-charts-world/actions/runs/36204426173), [Sep 26 second](https://github.com/pssguy/music-charts-world/actions/runs/36271048434) | Same mixed-period failure, worldwide September 24. |

None of these ten recent fetch failures reports a national outage, parse failure,
or integrity violation. Those failure categories are now tested defensively;
they are not claimed as observed causes of these runs.

## Approved publication policy: `india-stale-only-v1`

The user explicitly selected publication of the 54 current markets with India
visibly unavailable, excluded from calculations and rankings, and automatically
restored when current and valid.

This is a named exception, not an arbitrary coverage percentage. GLOBAL and all
54 other configured markets must validate for one period. India is fetched and
structurally validated on every run. Only a structurally valid India chart older
than GLOBAL may be excluded. Its chart rows are removed even from the saved
per-market result; its observed date, URL, attempt history, and reason remain as
diagnostics. No replacement data, backdating, cached chart, or stale rows are used.

Current valid India automatically restores 55/55. An India parse/integrity error,
HTTP failure, or ahead-of-worldwide period still blocks publication, as does any
failure or period mismatch in another market. Whole-source staleness remains
subject to the existing calendar freshness gate. Future/non-Thursday periods
are now also rejected. The existing live-manifest-unavailable warning policy
is unchanged; the exact expected-period check still applies.

Reduced coverage appears in the release report, public deployment manifest,
persistent site notice, analytical view notice, and disabled India chart selector.
All map, overlap, consensus, movement, and outlier calculations consume only the
current `charts` rows, so their denominator is 54 during the exception.

## Fetch-to-release behavior

1. Initialize a failure report and a blocked publication decision before R setup.
2. Fetch with explicit HTTP statuses and bounded timeouts. Retry transport errors,
   HTTP 408/429/5xx up to three times with exponential waits. HTTP 404/410 is
   `source_unavailable`; other non-200 responses are `http_error`. DNS messages
   containing “not found” cannot accidentally become allowed missing markets.
3. Parse the date/table/rows separately from rank, track ID, title, artist, and
   parser-loss validation. A wholly changed table produces `page_structure`
   instead of throwing while filtering an empty data frame. Unexpected per-market
   errors are contained, preserving results from other markets.
4. For mixed periods, perform at most two refresh rounds: refresh GLOBAL first,
   then only still-mismatched valid markets. Revalidate every fetched page and
   preserve all attempt histories. Persistent lag is `stale_publication`; a
   national period newer than GLOBAL is `period_ahead`. Apply the named India
   exception only after validation. No mixed-period rows enter the saved snapshot.
5. Write checkpoints before/after network attempts and after market validation.
   JSON includes GLOBAL, all configured markets, observed/required dates, URLs,
   attempt counts/history, failure categories and reasons. Only a completed pass
   writes a new RDS snapshot; a prior snapshot is removed before fetching.
6. The calendar/live-manifest gate still controls release action. Fetch failures
   do not invoke it. Always-run finalization preserves diagnostics and writes an
   explicit blocked decision when the gate was skipped, eliminating the misleading
   missing-file warning. Diagnostic artifacts last 30 days; JSON also appears in
   job logs and market details in the job summary. Snapshot artifacts remain one day.
7. Rendering, existing fresh-runner render recovery, generated-site tests, and
   deployment still require the successful upstream publication decision. The
   fetch step has a 20-minute limit inside the 35-minute job to leave cleanup time.

A forcibly destroyed runner cannot execute upload steps; checkpoints and per-market
log messages improve ordinary exceptions/timeouts but cannot guarantee artifact
delivery after infrastructure loss.

## Verification

Regression tests cover HTTP/DNS classification and bounded retry/recovery,
missing/changed/ambiguous pages, wholly unparseable tables, duplicate ranks/IDs,
persistent non-India mismatch, stale India exclusion, automatic restoration,
GLOBAL catching up, ahead-of-GLOBAL rejection, per-market exceptions, failed-run
snapshot removal, report serialization, setup/interruption diagnostics, and
freshness/workflow guards. See `tests/test_source_failures.R`,
`tests/test_validation_diagnostics.py`, and the existing parser/publication/site suites.

No workflow dispatch, production deployment, or merge was performed.

Local verification results:

- Python: 42 tests passed; both R parser/source-failure suites passed.
- Full live fetch: GLOBAL plus 54 current national charts at September 24; India
  remained August 20 after three fetches, explicitly unavailable, no stale rows.
- Live-manifest freshness check: September 24 accepted; the live site still
  reports August 20. This was a local decision only, not a deployment.
- Full local Quarto render succeeded (approximately 6.4 MB).
  Generated-site checks passed for the public metadata, queues, disabled India
  selector, coverage notices, and exclusion of India from analytical data.
- Official actionlint 1.7.12 and the release-configuration checker passed.
- Browser preview confirmed the coverage notice and disabled India entry.
- Local HTTP smoke test passed for the rendered page and 54-market manifest.
