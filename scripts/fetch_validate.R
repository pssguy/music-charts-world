#!/usr/bin/env Rscript

library(jsonlite)
source("R/fetch_charts.R")

args <- commandArgs(trailingOnly = TRUE)
output_dir <- if (length(args) >= 1L) args[[1]] else file.path("staging", "input")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
old_files <- list.files(output_dir, full.names = TRUE, all.files = TRUE, no.. = TRUE)
if (length(old_files) > 0L) unlink(old_files, recursive = TRUE, force = TRUE)

write_output <- function(name, value) {
  output_file <- Sys.getenv("GITHUB_OUTPUT")
  if (nzchar(output_file)) {
    cat(sprintf("%s=%s\n", name, gsub("[\r\n]+", " ", value)),
        file = output_file, append = TRUE)
  }
}

unexpected_error <- NULL
chart_run <- tryCatch(
  fetch_chart_run(
    WORLD_MUSIC_WATCH_COUNTRIES,
    top_n = CHART_VALIDATION$displayed_depth,
    fail_on_error = FALSE
  ),
  error = function(e) {
    unexpected_error <<- conditionMessage(e)
    NULL
  }
)

if (is.null(chart_run)) {
  chart_run <- list(
    chart_period = as.Date(NA),
    fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    coverage = tibble::tibble(
      configured_markets = length(WORLD_MUSIC_WATCH_COUNTRIES),
      successful_markets = 0L,
      failed_markets = length(WORLD_MUSIC_WATCH_COUNTRIES),
      unavailable_markets = 0L
    ),
    configured_markets = toupper(WORLD_MUSIC_WATCH_COUNTRIES),
    successful_markets = character(),
    failed_markets = toupper(WORLD_MUSIC_WATCH_COUNTRIES),
    unavailable_markets = character(),
    worldwide_row_count = 0L,
    warnings = character(),
    critical_failures = paste0("Unexpected fetch/validation failure: ", unexpected_error),
    validation_status = "fail",
    results = list()
  )
}

market_statuses <- lapply(chart_run$configured_markets, function(code) {
  result <- chart_run$results[[code]]
  if (is.null(result)) {
    return(list(code = code, status = "failed", errors = "No result was produced."))
  }
  list(
    code = code,
    status = result$status,
    source_url = result$source_url,
    chart_period = if (is.na(result$chart_period)) NA_character_ else as.character(result$chart_period),
    fetched_at = result$fetched_at,
    attempts = result$attempts,
    row_count = nrow(result$data),
    warnings = unname(result$warnings),
    errors = unname(result$errors)
  )
})

coverage <- as.list(chart_run$coverage[1, , drop = TRUE])
report <- list(
  schema_version = "1.0",
  chart_period = if (is.na(chart_run$chart_period)) NA_character_ else as.character(chart_run$chart_period),
  fetched_at = chart_run$fetched_at,
  coverage = coverage,
  successful_markets = unname(chart_run$successful_markets),
  failed_markets = unname(chart_run$failed_markets),
  unavailable_markets = unname(chart_run$unavailable_markets),
  worldwide_row_count = chart_run$worldwide_row_count,
  warnings = unname(chart_run$warnings),
  critical_failures = unname(chart_run$critical_failures),
  validation = list(
    status = chart_run$validation_status,
    warning_count = length(chart_run$warnings),
    critical_failure_count = length(chart_run$critical_failures)
  ),
  market_statuses = market_statuses
)

write_json(
  report,
  file.path(output_dir, "validation-report.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null",
  null = "null"
)

write_output("chart_period", if (is.na(chart_run$chart_period)) "unknown" else as.character(chart_run$chart_period))
write_output("fetched_at", chart_run$fetched_at)
write_output("configured_count", coverage$configured_markets)
write_output("successful_count", coverage$successful_markets)
write_output("failed_count", coverage$failed_markets)
write_output("unavailable_count", coverage$unavailable_markets)
write_output("configured_names", paste(chart_run$configured_markets, collapse = ", "))
write_output("successful_names", paste(chart_run$successful_markets, collapse = ", "))
write_output("failed_names", paste(chart_run$failed_markets, collapse = ", "))
write_output("unavailable_names", paste(chart_run$unavailable_markets, collapse = ", "))
write_output("worldwide_row_count", chart_run$worldwide_row_count)
write_output("warning_count", length(chart_run$warnings))
write_output("warning_messages", paste(chart_run$warnings, collapse = " | "))
write_output("critical_failure_count", length(chart_run$critical_failures))
write_output("critical_failures", paste(chart_run$critical_failures, collapse = " | "))
write_output("validation_status", chart_run$validation_status)

if (chart_run$validation_status != "pass") {
  message(paste(chart_run$critical_failures, collapse = "\n"))
  quit(save = "no", status = 1L)
}

saveRDS(chart_run, file.path(output_dir, "chart-run.rds"), compress = "xz")
cat("Full-market fetch and critical validation passed.\n")
