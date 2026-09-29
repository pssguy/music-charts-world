#!/usr/bin/env Rscript

library(jsonlite)
source("R/fetch_charts.R")
source("R/validation_report.R")

fetch_validate_main <- function(output_dir) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  # A previous snapshot can never survive a failed new fetch. Preserve the
  # bootstrap diagnostics installed before R setup, until the first checkpoint.
  unlink(file.path(output_dir, "chart-run.rds"))

  write_output <- function(name, value) {
    output_file <- Sys.getenv("GITHUB_OUTPUT")
    if (nzchar(output_file)) {
      cat(sprintf("%s=%s\n", name, gsub("[\r\n]+", " ", value)),
          file = output_file, append = TRUE)
    }
  }

  last_run <- NULL
  unexpected_error <- NULL
  chart_run <- tryCatch(
    fetch_chart_run(
      WORLD_MUSIC_WATCH_COUNTRIES,
      top_n = CHART_VALIDATION$displayed_depth,
      fail_on_error = FALSE,
      checkpoint = function(run) {
        last_run <<- run
        write_validation_report(run, output_dir)
      }
    ),
    error = function(e) {
      unexpected_error <<- conditionMessage(e)
      NULL
    }
  )

  if (is.null(chart_run)) {
    if (is.null(last_run)) {
      codes <- toupper(WORLD_MUSIC_WATCH_COUNTRIES)
      last_run <- summarize_chart_run(pending_chart_result("GLOBAL"),
        setNames(lapply(codes, pending_chart_result), codes), codes, complete = FALSE)
    }
    chart_run <- last_run
    chart_run$complete <- FALSE
    chart_run$validation_status <- "fail"
    chart_run$critical_failures <- c(chart_run$critical_failures,
      paste0("Unexpected fetch/validation failure: ", unexpected_error))
  }
  write_validation_report(chart_run, output_dir)
  coverage <- as.list(chart_run$coverage[1, , drop = TRUE])

  write_output("chart_period", if (is.na(chart_run$chart_period)) "unknown" else as.character(chart_run$chart_period))
  write_output("fetched_at", chart_run$fetched_at)
  write_output("source_url", chart_run$source_url)
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
    return(1L)
  }

  saveRDS(chart_run, file.path(output_dir, "chart-run.rds"), compress = "xz")
  cat(sprintf("Validation passed under india-stale-only-v1: %d/%d current markets; unavailable: %s.\n",
              coverage$successful_markets, coverage$configured_markets,
              paste(chart_run$unavailable_markets, collapse = ", ")))
  0L
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  output_dir <- if (length(args)) args[[1]] else file.path("staging", "input")
  quit(save = "no", status = fetch_validate_main(output_dir))
}
