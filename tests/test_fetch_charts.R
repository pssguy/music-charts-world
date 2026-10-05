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
optional_columns <- c("weeks", "peak", "peak_count", "streams", "streams_change", "total_streams")
stopifnot(all(optional_columns %in% names(parsed)), all(is.na(parsed[optional_columns])))

# Use the observed GB headers, but deliberately reorder them to catch positional
# parsing. Large totals must retain numeric precision beyond 32-bit integers.
headers <- c("Total", "Artist and Title", "Streams+", "(x?)", "P+", "Pos", "Pk", "Streams", "Wks")
values <- c("3,456,789,012", '<a href="../artist/a.html">Artist One</a> - <a href="../track/1234567890123456789012.html">Track One</a>',
            "-12,345", "(x7)", "+4", "17", "2", "1,234,567", "25")
rich_fixture <- function(headers, values) read_html(paste0(
  '<table class="sortable"><tr>', paste0("<th>", headers, "</th>", collapse = ""),
  '</tr><tr>', paste0("<td>", values, "</td>", collapse = ""), '</tr></table>'))
parse_fixture <- function(page) parse_kworb_row(html_elements(page, "tr")[[2]], "gb",
  "https://example.test/gb", as.Date("2026-07-09"), "2026-07-10T06:00:00Z")
rich <- parse_fixture(rich_fixture(headers, values))
stopifnot(rich$rank == 17L, rich$change == "+4", rich$title == "Track One",
          rich$artist == "Artist One", rich$weeks == 25L, rich$peak == 2L,
          rich$peak_count == 7L, rich$streams == 1234567,
          rich$streams_change == -12345, rich$total_streams == 3456789012)
for (header in c("Wks", "Pk", "(x?)", "Streams", "Streams+", "Total")) {
  keep <- headers != header
  missing <- parse_fixture(rich_fixture(headers[keep], values[keep]))
  column <- c(Wks = "weeks", Pk = "peak", "(x?)" = "peak_count", Streams = "streams",
              "Streams+" = "streams_change", Total = "total_streams")[[header]]
  stopifnot(is.na(missing[[column]]), missing$rank == 17L, missing$change == "+4")
}
blank_values <- values
blank_values[headers %in% c("Wks", "Pk", "(x?)", "Streams", "Streams+", "Total")] <- ""
stopifnot(all(is.na(parse_fixture(rich_fixture(headers, blank_values))[optional_columns])))
positive_values <- values
positive_values[headers == "Streams+"] <- "+12,345"
stopifnot(parse_fixture(rich_fixture(headers, positive_values))$streams_change == 12345)

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
fetch_kworb_country <- function(country_code, top_n, pause_seconds = 0, ...) {
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
stopifnot(length(failed_run$critical_failures) == 3L)
stopifnot(inherits(
  try(fetch_chart_run(c("us", "ca"), top_n = 1L, pause_seconds = 0), silent = TRUE),
  "try-error"
))
fetch_kworb_country <- real_fetch_kworb_country

# The actual fetcher must retain rank 200 even when the displayed depth is 50.
published_rows <- vapply(1:200, function(rank) sprintf(
  '<tr><td>%d</td><td>=</td><td><a href="../artist/a.html">Artist</a> - <a href="../track/%022d.html">Title %d</a></td><td>10</td><td>1</td><td>(x2)</td><td>1,000</td><td>+100</td><td>3,456,789,012</td></tr>',
  rank, rank, rank), character(1))
published <- paste0('<html><title>Spotify Weekly Chart - Test - 2026/07/09</title><body><table class="sortable"><tr>',
  paste0("<th>", c("Pos", "P+", "Artist and Title", "Wks", "Pk", "(x?)", "Streams", "Streams+", "Total"), "</th>", collapse = ""),
  '</tr>', paste(published_rows, collapse = ""), '</table></body></html>')
real_request <- request_chart
request_chart <- function(url, timeout_seconds) list(status_code = 200L, content = charToRaw(published))
full_chart <- fetch_kworb_country("gb", top_n = CHART_VALIDATION$displayed_depth)
request_chart <- real_request
stopifnot(full_chart$status == "success", identical(full_chart$data$rank, 1:200),
          all(full_chart$data$total_streams == 3456789012))

market <- function(code, stale = FALSE) {
  result <- full_chart
  result$country_code <- code
  result$data$country_code <- code
  if (code == "GB") {
    result$data$track_id[26:200] <- sprintf("%022d", 1026:1200)
  }
  if (stale) result$chart_period <- as.Date("2026-07-02")
  result
}
history_run <- summarize_chart_run(market("GLOBAL"),
  list(US = market("US"), GB = market("GB"), IN = market("IN", stale = TRUE)),
  c("US", "GB", "IN"))
stopifnot(history_run$validation_status == "pass", nrow(history_run$charts) == 400L,
          nrow(history_run$charts_global) == 200L)

# Exercise the QMD's real data-entry and metrics chunks without rendering or
# fetching. Tail ranks must not change Top 50 queues, overlap, or distinctiveness.
check_site_view <- function(run) {
  directory <- tempfile("site-view-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  path <- file.path(directory, "chart-run.rds")
  saveRDS(run, path)
  previous <- Sys.getenv("MUSICCHARTS_VALIDATED_RUN", unset = NA_character_)
  on.exit(if (is.na(previous)) Sys.unsetenv("MUSICCHARTS_VALIDATED_RUN") else
    Sys.setenv(MUSICCHARTS_VALIDATED_RUN = previous), add = TRUE)
  Sys.setenv(MUSICCHARTS_VALIDATED_RUN = path)
  qmd <- readLines("world-music-watch.qmd", warn = FALSE)
  chunk <- function(name) {
    start <- match(paste0("```{r ", name, "}"), qmd)
    end <- which(seq_along(qmd) > start & qmd == "```")[[1]]
    qmd[seq.int(start + 1L, end - 1L)]
  }
  country_codes <- tolower(run$configured_markets)
  eval(parse(text = chunk("fetch")))
  stopifnot(nrow(charts) == 100L, nrow(charts_global) == 50L,
            all(charts$rank <= CHART_VALIDATION$displayed_depth))
  eval(parse(text = chunk("metrics")))
  stopifnot(all(lengths(by_country) == 50L),
            isTRUE(all.equal(unname(strongest_pair_overlap), 1/3)),
            all(abs(stats$distinctiveness - 1/3) < 1e-10))
}
check_site_view(history_run)

check_history <- function(run) {
  directory <- tempfile("chart-history-test-")
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  folder <- write_chart_history(run, directory)
  charts <- read.csv(gzfile(file.path(folder, "charts.csv.gz")), stringsAsFactors = FALSE)
  markets <- read.csv(file.path(folder, "markets.csv"), stringsAsFactors = FALSE)
  stopifnot(identical(names(charts), c("chart_period", "fetched_at", "country_code", "rank",
    "change", "track_id", "title", "artist", "raw_artist_title", optional_columns)),
    nrow(charts) == 600L, all(table(charts$country_code) == 200L),
    all(charts$chart_period == "2026-07-09"), !"IN" %in% charts$country_code,
    all(charts$total_streams == 3456789012), nrow(markets) == 4L,
    markets$status[markets$country_code == "IN"] == "unavailable",
    markets$excluded[markets$country_code == "IN"],
    markets$row_count[markets$country_code == "IN"] == 0L,
    markets$observed_chart_period[markets$country_code == "IN"] == "2026-07-02")
  files <- file.path(folder, c("charts.csv.gz", "markets.csv"))
  before <- tools::md5sum(files)
  run$global_result$data$title <- "Changed data must not overwrite the first snapshot"
  stopifnot(identical(write_chart_history(run, directory), folder),
            identical(tools::md5sum(files), before))
  run$validation_status <- "fail"
  blocked_dir <- file.path(directory, "blocked")
  stopifnot(inherits(try(write_chart_history(run, blocked_dir), silent = TRUE), "try-error"),
            !dir.exists(blocked_dir))
}
check_history(history_run)

cat("fetch and validation fixture tests passed\n")
