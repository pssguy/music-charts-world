source("R/fetch_charts.R")

args <- commandArgs(trailingOnly = TRUE)
country_code <- if (length(args) > 0L) args[[1]] else "us"
result <- fetch_kworb_country(country_code, top_n = 50, pause_seconds = 0)
print(result[c("status", "chart_period", "attempts", "errors", "warnings")])
if (nrow(result$data) > 0L) {
  print(result$data[is.na(result$data$artist) | trimws(result$data$artist) == "", ])
}

if (result$status != "success") {
  stop("Live ", toupper(country_code), " chart fetch did not pass validation.")
}
stopifnot(nrow(result$data) == 50L)
stopifnot(identical(result$data$rank, seq_len(50L)))
stopifnot(length(unique(result$data$chart_period)) == 1L)

cat("live fetch passed for ", toupper(country_code), " chart period ",
    as.character(result$chart_period), "\n", sep = "")
