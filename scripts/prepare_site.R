#!/usr/bin/env Rscript

library(jsonlite)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3L) {
  stop("Usage: prepare_site.R SITE_DIR CHART_RUN_RDS VALIDATION_REPORT_JSON")
}

site_dir <- args[[1]]
run_path <- args[[2]]
validation_path <- args[[3]]
render_report_path <- if (length(args) >= 4L) {
  args[[4]]
} else {
  file.path(dirname(site_dir), "render-report.json")
}
chart_run <- readRDS(run_path)
validation_report <- read_json(validation_path, simplifyVector = FALSE)

required <- c("index.html", "CNAME", "robots.txt")
missing <- required[!file.exists(file.path(site_dir, required))]
if (length(missing) > 0L) stop("Rendered site is missing: ", paste(missing, collapse = ", "))

site_root <- normalizePath(site_dir, winslash = "/", mustWork = TRUE)
site_files <- list.files(site_root, recursive = TRUE, full.names = TRUE, all.files = TRUE)
site_files <- site_files[!file.info(site_files)$isdir]
sizes <- file.info(site_files)$size
relative_files <- substring(normalizePath(site_files, winslash = "/"), nchar(site_root) + 2L)
names(sizes) <- relative_files
index_bytes <- unname(sizes[["index.html"]])
site_bytes <- sum(sizes, na.rm = TRUE)

if (any(is.na(sizes)) || any(sizes == 0L)) {
  stop("Rendered output contains an unreadable or empty file.")
}
if (index_bytes < 100 * 1024) {
  stop(sprintf("Rendered index.html is unexpectedly small (%d bytes).", index_bytes))
}
if (site_bytes < 250 * 1024) {
  stop(sprintf("Rendered site is unexpectedly small (%d bytes).", site_bytes))
}

render_warnings <- character()
previous_bytes <- suppressWarnings(as.numeric(Sys.getenv("MUSICCHARTS_PREVIOUS_SITE_BYTES")))
if (!is.na(previous_bytes) && previous_bytes > 0L &&
    site_bytes > previous_bytes * 1.5 && site_bytes - previous_bytes > 5 * 1024^2) {
  render_warnings <- c(
    render_warnings,
    sprintf("Rendered site grew from %.1f MB to %.1f MB.", previous_bytes / 1024^2, site_bytes / 1024^2)
  )
}
if (site_bytes > 100 * 1024^2) {
  render_warnings <- c(render_warnings, sprintf("Rendered site is large (%.1f MB).", site_bytes / 1024^2))
}

manifest <- list(
  schema_version = "1.0",
  chart_period = as.character(chart_run$chart_period),
  fetched_at = chart_run$fetched_at,
  configured_markets = unname(chart_run$configured_markets),
  successful_markets = unname(chart_run$successful_markets),
  failed_markets = unname(chart_run$failed_markets),
  unavailable_markets = unname(chart_run$unavailable_markets),
  market_statuses = validation_report$market_statuses,
  worldwide_row_count = chart_run$worldwide_row_count,
  site_bytes = site_bytes,
  warning_count = length(unique(c(unname(chart_run$warnings), render_warnings))),
  warnings = unique(c(unname(chart_run$warnings), render_warnings)),
  validation = list(
    status = chart_run$validation_status,
    critical_failure_count = length(chart_run$critical_failures)
  ),
  commit = Sys.getenv("GITHUB_SHA", unset = "local"),
  workflow = Sys.getenv("GITHUB_WORKFLOW", unset = "local"),
  run_id = Sys.getenv("GITHUB_RUN_ID", unset = "local"),
  run_attempt = Sys.getenv("GITHUB_RUN_ATTEMPT", unset = "1"),
  rendered_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  deployed_at = NA_character_
)
write_json(
  manifest,
  file.path(site_dir, "deployment-manifest.json"),
  auto_unbox = TRUE,
  pretty = FALSE,
  na = "null",
  null = "null"
)

render_report <- list(
  schema_version = "1.0",
  index_bytes = index_bytes,
  site_bytes = site_bytes,
  file_count = length(site_files) + 1L,
  warnings = render_warnings,
  validation_status = chart_run$validation_status
)
write_json(
  render_report,
  render_report_path,
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null",
  null = "null"
)

output_file <- Sys.getenv("GITHUB_OUTPUT")
if (nzchar(output_file)) {
  cat(sprintf("site_bytes=%d\nindex_bytes=%d\nfile_count=%d\nrender_warning_count=%d\n",
              site_bytes, index_bytes, length(site_files) + 1L, length(render_warnings)),
      file = output_file, append = TRUE)
}
cat(sprintf("Prepared %d files (%.1f MB).\n", length(site_files) + 1L, site_bytes / 1024^2))
