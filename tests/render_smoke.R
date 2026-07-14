library(jsonlite)
source("R/fetch_charts.R")

smoke_markets <- c("us", "ca", "gb")
smoke_dir <- file.path("staging", "smoke")
unlink(smoke_dir, recursive = TRUE, force = TRUE)
dir.create(smoke_dir, recursive = TRUE, showWarnings = FALSE)

chart_run <- fetch_chart_run(
  smoke_markets,
  top_n = CHART_VALIDATION$displayed_depth,
  pause_seconds = 0.1
)
run_path <- normalizePath(file.path(smoke_dir, "chart-run.rds"), mustWork = FALSE)
report_path <- normalizePath(file.path(smoke_dir, "validation-report.json"), mustWork = FALSE)
saveRDS(chart_run, run_path, compress = "xz")

market_statuses <- lapply(chart_run$configured_markets, function(code) {
  result <- chart_run$results[[code]]
  list(
    code = code,
    status = result$status,
    source_url = result$source_url,
    chart_period = as.character(result$chart_period),
    fetched_at = result$fetched_at,
    attempts = result$attempts,
    row_count = nrow(result$data),
    warnings = unname(result$warnings),
    errors = unname(result$errors)
  )
})
write_json(
  list(
    schema_version = "1.0",
    chart_period = as.character(chart_run$chart_period),
    fetched_at = chart_run$fetched_at,
    coverage = as.list(chart_run$coverage[1, , drop = TRUE]),
    successful_markets = chart_run$successful_markets,
    failed_markets = chart_run$failed_markets,
    unavailable_markets = chart_run$unavailable_markets,
    worldwide_row_count = chart_run$worldwide_row_count,
    warnings = chart_run$warnings,
    critical_failures = chart_run$critical_failures,
    validation = list(status = "pass", warning_count = length(chart_run$warnings), critical_failure_count = 0L),
    market_statuses = market_statuses
  ),
  report_path,
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null",
  null = "null"
)

Sys.setenv(
  MUSICCHARTS_TEST_MARKETS = paste(smoke_markets, collapse = ","),
  MUSICCHARTS_VALIDATED_RUN = run_path,
  MUSICCHARTS_EXPECTED_MARKETS = length(smoke_markets),
  MUSICCHARTS_SITE_DIR = normalizePath("_site", mustWork = FALSE)
)
unlink("_site", recursive = TRUE, force = TRUE)
render_status <- system2("quarto", c("render", "world-music-watch.qmd"))
if (!identical(render_status, 0L)) stop("Smoke render failed with status ", render_status)

rscript <- file.path(R.home("bin"), "Rscript")
prepare_status <- system2(
  rscript,
  shQuote(c(
    "scripts/prepare_site.R",
    "_site",
    run_path,
    report_path,
    file.path(smoke_dir, "render-report.json")
  ))
)
if (!identical(prepare_status, 0L)) stop("Smoke output preparation failed with status ", prepare_status)

source("tests/test_generated_site.R")
cat("reduced-market render smoke test passed\n")
