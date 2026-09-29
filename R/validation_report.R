# Shared by the final report and per-market checkpoints. No chart rows in JSON.
chart_validation_report <- function(run) {
  json_array <- function(value) unname(as.list(value))
  market_status <- function(result) {
    list(code = result$country_code, status = result$status,
         failure_type = result$failure_type, source_url = result$source_url,
         chart_period = as.character(result$chart_period),
         required_period = as.character(run$chart_period),
         fetched_at = result$fetched_at, attempts = result$attempts,
         attempt_history = result$attempt_history, row_count = nrow(result$data),
         observed_row_count = result$observed_row_count,
         parser_failure_rate = result$parser_failure_rate,
         warnings = json_array(result$warnings), errors = json_array(result$errors))
  }
  list(
    schema_version = "2.0", complete = run$complete,
    coverage_policy = run$coverage_policy,
    chart_period = as.character(run$chart_period), fetched_at = run$fetched_at,
    source_url = run$source_url, coverage = as.list(run$coverage[1, , drop = TRUE]),
    configured_markets = json_array(run$configured_markets),
    successful_markets = json_array(run$successful_markets),
    failed_markets = json_array(run$failed_markets),
    unavailable_markets = json_array(run$unavailable_markets),
    excluded_markets = json_array(run$excluded_markets),
    worldwide_row_count = run$worldwide_row_count,
    warnings = json_array(run$warnings), critical_failures = json_array(run$critical_failures),
    validation = list(status = run$validation_status,
                      warning_count = length(run$warnings),
                      critical_failure_count = length(run$critical_failures)),
    worldwide_status = market_status(run$global_result),
    market_statuses = unname(lapply(run$results, market_status))
  )
}

write_validation_report <- function(run, output_dir) {
  path <- file.path(output_dir, "validation-report.json")
  jsonlite::write_json(chart_validation_report(run), paste0(path, ".tmp"),
                       auto_unbox = TRUE, pretty = TRUE, na = "null", null = "null")
  if (!file.rename(paste0(path, ".tmp"), path)) stop("Could not replace validation report.")
}
