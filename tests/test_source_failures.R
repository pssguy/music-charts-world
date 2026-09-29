source("scripts/fetch_validate.R")

fixture_html <- function(period = "2026/09/24", ranks = 1:50, ids = ranks) {
  rows <- vapply(seq_along(ranks), function(i) sprintf(
    '<tr><td>%d</td><td>=</td><td><a href="../artist/a.html">Artist</a> - <a href="../track/%022d.html">Title</a></td></tr>',
    ranks[i], ids[i]), character(1))
  paste0('<html><title>Spotify Weekly Chart - Test - ', period,
         '</title><body><table class="sortable"><tr><th>Pos</th></tr>',
         paste(rows, collapse = ""), '</table></body></html>')
}

# HTTP status, not an ambiguous substring such as "host not found", determines
# source unavailability. Transient errors retry; permanent responses do not.
for (status in c(404L, 410L, 403L, 429L, 503L, NA_integer_)) {
  calls <- 0L
  transport <- function(url, timeout_seconds) {
    calls <<- calls + 1L
    if (is.na(status)) stop("Could not resolve host: not found")
    list(status_code = status, content = charToRaw("error"))
  }
  fetched <- fetch_html_with_retry("https://example.test/in", request = transport, sleep = function(x) NULL)
  transient <- is.na(status) || status %in% c(429L, 503L)
  stopifnot(calls == if (transient) 3L else 1L,
            length(fetched$attempt_history) == calls,
            fetched$failure_type == if (transient) "temporary_network" else if (status %in% c(404L, 410L)) "source_unavailable" else "http_error")
}
calls <- 0L
recovered <- fetch_html_with_retry("https://example.test/in", sleep = function(x) NULL,
  request = function(url, timeout_seconds) {
    calls <<- calls + 1L
    if (calls == 1L) stop("Timeout")
    list(status_code = 200L, content = charToRaw(fixture_html()))
  })
stopifnot(recovered$attempts == 2L, !is.null(recovered$page),
          recovered$attempt_history[[1]]$failure_type == "temporary_network")

real_request <- request_chart
test_page <- fixture_html()
request_chart <- function(url, timeout_seconds) list(status_code = 200L, content = charToRaw(test_page))
stopifnot(fetch_kworb_country("in")$status == "success")
test_page <- sub('class="sortable"', 'class="changed"', fixture_html(), fixed = TRUE)
stopifnot(fetch_kworb_country("in")$failure_type == "page_structure")
test_page <- '<html><title>Changed heading</title><body>Unavailable</body></html>'
stopifnot(fetch_kworb_country("in")$failure_type == "page_structure")
test_page <- sub("</body>", "<h1>Spotify Weekly Chart - Test - 2026/09/17</h1></body>", fixture_html())
stopifnot(fetch_kworb_country("in")$failure_type == "page_structure")
test_page <- gsub("track/", "changed/", fixture_html(), fixed = TRUE)
stopifnot(fetch_kworb_country("in")$failure_type == "page_structure")
test_page <- fixture_html(ids = rep(1L, 50))
stopifnot(fetch_kworb_country("in")$failure_type == "data_integrity")
test_page <- fixture_html(ranks = c(1:49, 49L))
stopifnot(fetch_kworb_country("in")$failure_type == "data_integrity")
request_chart <- real_request

result <- function(code, period = "2026-09-24", status = "success") {
  value <- pending_chart_result(code)
  value$status <- status
  value$chart_period <- as.Date(period)
  value$data <- tibble(country_code = code, rank = 1:50, track_id = paste0(code, 1:50))
  value$attempts <- 1L
  value$attempt_history <- list(list(attempt = 1L, chart_period = period, http_status = 200L))
  value$errors <- character()
  value$failure_type <- NULL
  value
}
no_sleep <- function(seconds) NULL
frozen <- function(country_code, ...) result(country_code, if (country_code == "IN") "2026-08-20" else "2026-09-24")
run <- fetch_chart_run(c("us", "in"), fetch_country = frozen, sleep = no_sleep, fail_on_error = FALSE)
stopifnot(run$validation_status == "pass", identical(run$excluded_markets, "IN"),
          run$results$IN$failure_type == "stale_publication",
          run$results$IN$attempts == 3L, run$results$US$attempts == 1L,
          !"IN" %in% run$charts$country_code, nrow(run$results$IN$data) == 0L,
          all(c("2026-08-20", "2026-09-24", "35", "in_weekly.html", "attempts=3") |> vapply(
            function(s) grepl(s, market_failure_detail(run$results$IN), fixed = TRUE), logical(1))))
other_stale <- function(country_code, ...) result(country_code, if (country_code == "CA") "2026-08-20" else "2026-09-24")
blocked <- fetch_chart_run(c("us", "ca"), fetch_country = other_stale, sleep = no_sleep, fail_on_error = FALSE)
stopifnot(blocked$validation_status == "fail", blocked$results$CA$failure_type == "stale_publication")
ahead <- function(country_code, ...) result(country_code, if (country_code == "IN") "2026-10-01" else "2026-09-24")
stopifnot(fetch_chart_run("in", fetch_country = ahead, sleep = no_sleep, fail_on_error = FALSE)$validation_status == "fail")

# A publication race can recover only by refetching current validated data.
calls <- 0L
converging <- function(country_code, ...) {
  if (country_code == "IN") calls <<- calls + 1L
  result(country_code, if (country_code == "IN" && calls == 1L) "2026-09-17" else "2026-09-24")
}
run <- fetch_chart_run(c("us", "in"), fetch_country = converging, sleep = no_sleep)
stopifnot(run$validation_status == "pass", run$results$IN$attempts == 2L,
          run$results$IN$attempt_history[[1]]$chart_period == "2026-09-17",
          "IN" %in% run$charts$country_code, !length(run$excluded_markets))

# GLOBAL may be the page that lags; refresh it before retrying national pages.
calls <- 0L
global_lag <- function(country_code, ...) {
  if (country_code == "GLOBAL") calls <<- calls + 1L
  result(country_code, if (country_code == "GLOBAL" && calls == 1L) "2026-09-17" else "2026-09-24")
}
run <- fetch_chart_run(c("us", "in"), fetch_country = global_lag, sleep = no_sleep)
stopifnot(run$global_result$attempts == 2L, run$results$IN$attempts == 1L)

broken <- function(country_code, ...) {
  if (country_code == "IN") stop("Unexpected parser exception")
  result(country_code)
}
checkpoints <- list()
run <- fetch_chart_run(c("us", "in", "ca"), fetch_country = broken, fail_on_error = FALSE,
  checkpoint = function(run) checkpoints[[length(checkpoints) + 1L]] <<- run)
stopifnot(run$results$IN$failure_type == "unexpected_error", run$results$CA$status == "success",
          run$results$US$status == "success", !checkpoints[[1]]$complete)

missing <- function(country_code, ...) result(country_code, status = if (country_code == "IN") "unavailable" else "success")
stopifnot(fetch_chart_run(c("us", "in"), fetch_country = missing, fail_on_error = FALSE)$validation_status == "fail")

# Exercise the real writer/main with a deterministic 56-source frozen-IN run.
real_fetch <- fetch_kworb_country
fetch_kworb_country <- frozen
CHART_VALIDATION$period_refresh_wait_seconds <- 0
directory <- tempfile("validation-test-")
dir.create(directory)
saveRDS("old snapshot must not survive", file.path(directory, "chart-run.rds"))
exit_code <- fetch_validate_main(directory)
report <- jsonlite::read_json(file.path(directory, "validation-report.json"), simplifyVector = FALSE)
india <- Filter(function(x) x$code == "IN", report$market_statuses)[[1]]
stopifnot(exit_code == 0L, file.exists(file.path(directory, "chart-run.rds")),
          length(report$market_statuses) == 55L, report$worldwide_status$code == "GLOBAL",
          india$chart_period == "2026-08-20", india$required_period == "2026-09-24",
          india$failure_type == "stale_publication", india$attempts == 3L,
          report$coverage$successful_markets == 54L)
saved <- readRDS(file.path(directory, "chart-run.rds"))
stopifnot(!"IN" %in% saved$charts$country_code, nrow(saved$results$IN$data) == 0L,
          nrow(saved$charts) == 54L * 50L)
fetch_kworb_country <- other_stale
stopifnot(fetch_validate_main(directory) == 1L,
          !file.exists(file.path(directory, "chart-run.rds")))
fetch_kworb_country <- real_fetch
cat("source failure, retry, period synchronization, and report tests passed\n")
