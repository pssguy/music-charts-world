source("R/fetch_charts.R")

stopifnot(identical(escape_chart_text("A$$AP"), "A&#36;&#36;AP"))
stopifnot(identical(
  escape_chart_text('A$$AP "live"', attribute = TRUE),
  "A&#36;&#36;AP &quot;live&quot;"
))

fixture <- read_html('<html><head><title>Spotify Weekly Chart - Testland - 2026/07/09</title></head><body><table class="sortable"><tr><th>Pos</th><th>P+</th><th>Artist and Title</th></tr><tr><td>1</td><td>=</td><td><a href="../artist/a.html">Artist One</a> - <a href="../track/1234567890123456789012.html">Track One</a></td></tr><tr><td>broken</td><td>NEW</td><td>unparseable row</td></tr><tr><td>3</td><td>+2</td><td><a href="../artist/b.html">Artist Two</a> - <a href="../track/abcdefghijklmnopqrstuv.html">Track Two</a></td></tr></table></body></html>')

stopifnot(identical(extract_kworb_chart_period(fixture), as.Date("2026-07-09")))

rows <- html_elements(html_element(fixture, "table.sortable"), "tr")[-1]
parsed_rows <- lapply(
  rows,
  parse_kworb_row,
  country_code = "xx",
  source_url = "https://example.test/chart",
  chart_period = as.Date("2026-07-09"),
  fetched_at = "2026-07-10T06:00:00Z"
)
parsed <- bind_rows(parsed_rows)

# A malformed source row must not cause the following source rank to be renumbered.
stopifnot(identical(parsed$rank, c(1L, 3L)))
stopifnot(identical(parsed$raw_rank, c("1", "3")))

validation <- validate_chart(
  parsed,
  raw_row_count = 3L,
  parse_failure_count = 1L,
  top_n = 3L
)
stopifnot(!validation$valid)
stopifnot(any(grepl("Missing displayed ranks: 2", validation$errors, fixed = TRUE)))
stopifnot(any(grepl("Parser failure rate", validation$errors, fixed = TRUE)))

duplicate <- bind_rows(parsed[1, ], transform(parsed[1, ], title = "Duplicate"))
duplicate_validation <- validate_chart(
  duplicate,
  raw_row_count = 2L,
  parse_failure_count = 0L,
  top_n = 1L
)
stopifnot(!duplicate_validation$valid)
stopifnot(any(grepl("Duplicate ranks", duplicate_validation$errors, fixed = TRUE)))
stopifnot(any(grepl("Duplicate track IDs", duplicate_validation$errors, fixed = TRUE)))

# Run-level validation must return a report before it raises, so CI can publish
# useful failure diagnostics while still blocking the render job.
real_fetch_kworb_country <- fetch_kworb_country
fetch_kworb_country <- function(country_code, top_n, pause_seconds = 0) {
  code <- toupper(country_code)
  status <- if (code == "CA") "failed" else if (code == "GB") "unavailable" else "success"
  list(
    country_code = code,
    status = status,
    source_url = paste0("https://example.test/", tolower(code)),
    chart_period = if (status == "success") as.Date("2026-07-09") else as.Date(NA),
    fetched_at = "2026-07-10T06:00:00Z",
    attempts = 1L,
    data = if (status == "success") tibble(rank = 1L) else tibble(),
    errors = if (status == "failed") "fixture validation error" else character(),
    warnings = character()
  )
}
failed_run <- fetch_chart_run(c("us", "ca", "gb"), top_n = 1L, pause_seconds = 0, fail_on_error = FALSE)
stopifnot(identical(failed_run$validation_status, "fail"))
stopifnot(identical(failed_run$failed_markets, "CA"))
stopifnot(identical(failed_run$unavailable_markets, "GB"))
stopifnot(length(failed_run$critical_failures) == 1L)
stopifnot(inherits(
  try(fetch_chart_run(c("us", "ca"), top_n = 1L, pause_seconds = 0), silent = TRUE),
  "try-error"
))
fetch_kworb_country <- real_fetch_kworb_country

cat("fetch and validation fixture tests passed\n")
