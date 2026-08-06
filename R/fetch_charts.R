# R/fetch_charts.R
# Fetches and validates the current Kworb Spotify weekly chart snapshot.

library(rvest)
library(dplyr)
library(stringr)
library(tibble)

CHART_VALIDATION <- list(
  published_depth = 200L,
  displayed_depth = 50L,
  minimum_rows = 50L,
  maximum_parser_failure_rate = 0.02,
  track_id_pattern = "^[A-Za-z0-9]{22}$",
  fetch_attempts = 3L,
  retry_wait_seconds = 1,
  request_timeout_seconds = 30L
)

# Escape source-provided display text for raw HTML emitted through Quarto.
# Dollar signs are valid chart content, but Pandoc can otherwise interpret
# paired dollars as inline math before the raw HTML reaches the final page.
escape_chart_text <- function(value, attribute = FALSE) {
  escaped <- as.character(htmltools::htmlEscape(value, attribute = attribute))
  gsub("$", "&#36;", escaped, fixed = TRUE)
}

kworb_chart_url <- function(country_code) {
  sprintf(
    "https://kworb.net/spotify/country/%s_weekly.html",
    tolower(country_code)
  )
}

extract_kworb_chart_period <- function(page) {
  candidates <- c(
    html_text2(html_elements(page, "title, h1")),
    html_text2(html_element(page, "body"))
  )
  matches <- str_match(
    candidates,
    "Spotify Weekly Chart[^\r\n]*?-\\s*(\\d{4}/\\d{2}/\\d{2})"
  )[, 2]
  periods <- unique(as.Date(na.omit(matches), format = "%Y/%m/%d"))

  if (length(periods) != 1L || is.na(periods[[1]])) {
    stop("Could not verify one unambiguous chart period from the source page.")
  }
  periods[[1]]
}

classify_fetch_error <- function(message) {
  if (str_detect(message, regex("404|not found", ignore_case = TRUE))) {
    "unavailable"
  } else {
    "failed"
  }
}

fetch_html_with_retry <- function(url,
                                  attempts = CHART_VALIDATION$fetch_attempts,
                                  wait_seconds = CHART_VALIDATION$retry_wait_seconds,
                                  timeout_seconds = CHART_VALIDATION$request_timeout_seconds) {
  old_timeout <- getOption("timeout")
  options(timeout = timeout_seconds)
  on.exit(options(timeout = old_timeout), add = TRUE)

  last_error <- NULL
  for (attempt in seq_len(attempts)) {
    page <- tryCatch(read_html(url), error = function(e) {
      last_error <<- conditionMessage(e)
      NULL
    })
    if (!is.null(page)) {
      return(list(page = page, attempts = attempt, error = NULL))
    }
    if (attempt < attempts) Sys.sleep(wait_seconds * attempt)
  }
  if (is.null(last_error)) last_error <- "Unknown fetch error"
  list(page = NULL, attempts = attempts, error = last_error)
}

parse_kworb_row <- function(row, country_code, source_url, chart_period,
                            fetched_at) {
  cells <- html_elements(row, "td")
  if (length(cells) < 3L) return(NULL)

  raw_rank <- html_text2(cells[[1]])
  rank <- suppressWarnings(as.integer(str_extract(raw_rank, "^\\d+")))
  raw_change <- html_text2(cells[[2]])
  raw_artist_title <- html_text2(cells[[3]])

  links <- html_elements(cells[[3]], "a")
  hrefs <- html_attr(links, "href")
  track_idx <- which(str_detect(hrefs, "track/"))
  artist_idx <- which(str_detect(hrefs, "artist/"))
  if (length(track_idx) == 0L) return(NULL)

  track_href <- hrefs[[track_idx[[1]]]]
  track_id <- str_match(track_href, "track/([A-Za-z0-9]+)\\.html")[, 2]
  if (is.na(rank) || is.na(track_id)) return(NULL)

  tibble(
    country_code = toupper(country_code),
    rank = rank,
    title = html_text2(links[[track_idx[[1]]]]),
    artist = if (length(artist_idx) > 0L) {
      html_text2(links[[artist_idx[[1]]]])
    } else {
      NA_character_
    },
    change = raw_change,
    track_id = track_id,
    track_url = paste0("https://open.spotify.com/track/", track_id),
    source_url = source_url,
    chart_period = chart_period,
    fetched_at = fetched_at,
    raw_rank = raw_rank,
    raw_change = raw_change,
    raw_artist_title = raw_artist_title
  )
}

validate_chart <- function(data, raw_row_count, parse_failure_count,
                           top_n = CHART_VALIDATION$displayed_depth) {
  errors <- character()
  warnings <- character()
  ranks <- data$rank
  displayed <- data[data$rank <= top_n, , drop = FALSE]

  if (nrow(data) < CHART_VALIDATION$minimum_rows) {
    errors <- c(errors, sprintf("Only %d usable rows were parsed.", nrow(data)))
  }
  if (any(is.na(ranks)) || any(ranks < 1L | ranks > CHART_VALIDATION$published_depth)) {
    errors <- c(errors, "Ranks contain missing or out-of-range values.")
  }
  duplicate_ranks <- unique(ranks[duplicated(ranks)])
  if (length(duplicate_ranks) > 0L) {
    errors <- c(errors, paste("Duplicate ranks:", paste(duplicate_ranks, collapse = ", ")))
  }

  displayed_ranks <- sort(ranks[ranks <= top_n])
  missing_displayed_ranks <- setdiff(seq_len(top_n), displayed_ranks)
  if (length(missing_displayed_ranks) > 0L) {
    errors <- c(
      errors,
      paste("Missing displayed ranks:", paste(missing_displayed_ranks, collapse = ", "))
    )
  }
  if (anyDuplicated(displayed$track_id)) {
    errors <- c(errors, "Duplicate track IDs occur within the displayed chart.")
  }
  if (any(is.na(displayed$track_id) | !str_detect(displayed$track_id, CHART_VALIDATION$track_id_pattern))) {
    errors <- c(errors, "One or more displayed track IDs are missing or invalid.")
  }
  if (any(is.na(displayed$title) | trimws(displayed$title) == "")) {
    errors <- c(errors, "One or more displayed titles are missing.")
  }
  if (any(is.na(displayed$artist) | trimws(displayed$artist) == "")) {
    errors <- c(errors, "One or more displayed primary artists are missing.")
  }

  failure_rate <- if (raw_row_count > 0L) parse_failure_count / raw_row_count else 1
  if (failure_rate > CHART_VALIDATION$maximum_parser_failure_rate) {
    errors <- c(
      errors,
      sprintf("Parser failure rate %.1f%% exceeds %.1f%%.",
              failure_rate * 100,
              CHART_VALIDATION$maximum_parser_failure_rate * 100)
    )
  } else if (parse_failure_count > 0L) {
    warnings <- c(warnings, sprintf("%d source rows could not be parsed.", parse_failure_count))
  }

  list(
    valid = length(errors) == 0L,
    errors = errors,
    warnings = warnings,
    parser_failure_rate = failure_rate
  )
}

fetch_kworb_country <- function(country_code,
                                top_n = CHART_VALIDATION$displayed_depth,
                                pause_seconds = 0) {
  source_url <- kworb_chart_url(country_code)
  fetched_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  fetched <- fetch_html_with_retry(source_url)

  if (is.null(fetched$page)) {
    return(list(
      country_code = toupper(country_code),
      status = classify_fetch_error(fetched$error),
      source_url = source_url,
      chart_period = as.Date(NA),
      fetched_at = fetched_at,
      attempts = fetched$attempts,
      data = tibble(),
      errors = fetched$error,
      warnings = character()
    ))
  }

  chart_period <- tryCatch(
    extract_kworb_chart_period(fetched$page),
    error = function(e) e
  )
  if (inherits(chart_period, "error")) {
    return(list(
      country_code = toupper(country_code),
      status = "failed",
      source_url = source_url,
      chart_period = as.Date(NA),
      fetched_at = fetched_at,
      attempts = fetched$attempts,
      data = tibble(),
      errors = conditionMessage(chart_period),
      warnings = character()
    ))
  }

  table_node <- html_element(fetched$page, "table.sortable")
  rows <- if (inherits(table_node, "xml_missing")) {
    list()
  } else {
    html_elements(table_node, "tr")
  }
  if (length(rows) < 2L) {
    return(list(
      country_code = toupper(country_code),
      status = "failed",
      source_url = source_url,
      chart_period = chart_period,
      fetched_at = fetched_at,
      attempts = fetched$attempts,
      data = tibble(),
      errors = "No chart table rows were found.",
      warnings = character()
    ))
  }

  parsed_rows <- lapply(
    rows[-1],
    parse_kworb_row,
    country_code = country_code,
    source_url = source_url,
    chart_period = chart_period,
    fetched_at = fetched_at
  )
  parsed <- bind_rows(parsed_rows)
  parse_failure_count <- sum(vapply(parsed_rows, is.null, logical(1)))
  validation <- validate_chart(
    parsed,
    raw_row_count = length(rows) - 1L,
    parse_failure_count = parse_failure_count,
    top_n = top_n
  )

  if (pause_seconds > 0) Sys.sleep(pause_seconds)

  list(
    country_code = toupper(country_code),
    status = if (validation$valid) "success" else "failed",
    source_url = source_url,
    chart_period = chart_period,
    fetched_at = fetched_at,
    attempts = fetched$attempts,
    data = parsed |>
      filter(rank <= top_n) |>
      arrange(rank),
    errors = validation$errors,
    warnings = validation$warnings,
    parser_failure_rate = validation$parser_failure_rate
  )
}

fetch_chart_run <- function(country_codes,
                            top_n = CHART_VALIDATION$displayed_depth,
                            pause_seconds = 0.5,
                            fail_on_error = TRUE) {
  global <- fetch_kworb_country("global", top_n = top_n)
  results <- lapply(country_codes, function(code) {
    message("Fetching ", toupper(code), "...")
    fetch_kworb_country(code, top_n = top_n, pause_seconds = pause_seconds)
  })
  names(results) <- toupper(country_codes)

  failed <- names(results)[vapply(results, function(x) x$status == "failed", logical(1))]
  unavailable <- names(results)[vapply(results, function(x) x$status == "unavailable", logical(1))]
  successful <- names(results)[vapply(results, function(x) x$status == "success", logical(1))]

  critical_failures <- character()
  if (global$status != "success") {
    critical_failures <- c(
      critical_failures,
      paste0("Worldwide chart validation failed: ", paste(global$errors, collapse = "; "))
    )
  }
  if (length(failed) > 0L) {
    details <- vapply(results[failed], function(x) paste(x$errors, collapse = "; "), character(1))
    critical_failures <- c(
      critical_failures,
      paste0(
        "National chart validation failed: ",
        paste(sprintf("%s (%s)", failed, details), collapse = "; ")
      )
    )
  }

  successful_periods <- if (length(successful) > 0L) {
    unique(as.Date(vapply(
      results[successful],
      function(x) as.character(x$chart_period),
      character(1)
    )))
  } else {
    as.Date(character())
  }
  if (length(successful) == 0L) {
    critical_failures <- c(
      critical_failures,
      "No configured national market produced a validated chart."
    )
  } else if (
    global$status == "success" &&
      (length(successful_periods) != 1L || successful_periods[[1]] != global$chart_period)
  ) {
    critical_failures <- c(
      critical_failures,
      "Chart periods do not match the verified worldwide chart period."
    )
  }

  warnings <- c(
    unlist(lapply(c(list(GLOBAL = global), results), `[[`, "warnings"), use.names = FALSE),
    if (length(unavailable) > 0L) {
      paste0("Source chart unavailable for: ", paste(unavailable, collapse = ", "))
    } else {
      character()
    }
  )

  coverage <- tibble(
    configured_markets = length(country_codes),
    successful_markets = length(successful),
    failed_markets = length(failed),
    unavailable_markets = length(unavailable)
  )

  fetched_times <- c(global$fetched_at, vapply(results, `[[`, character(1), "fetched_at"))
  fetched_times <- as.POSIXct(fetched_times, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  run <- list(
    chart_period = global$chart_period,
    fetched_at = format(
      max(fetched_times, na.rm = TRUE),
      "%Y-%m-%dT%H:%M:%SZ",
      tz = "UTC"
    ),
    source_url = global$source_url,
    charts_global = global$data,
    charts = bind_rows(lapply(results[successful], `[[`, "data")),
    results = results,
    coverage = coverage,
    configured_markets = toupper(country_codes),
    successful_markets = successful,
    failed_markets = failed,
    unavailable_markets = unavailable,
    worldwide_row_count = nrow(global$data),
    warnings = warnings,
    critical_failures = critical_failures,
    validation_status = if (length(critical_failures) == 0L) "pass" else "fail"
  )

  if (fail_on_error && run$validation_status != "pass") {
    stop(paste(run$critical_failures, collapse = " "), call. = FALSE)
  }
  run
}

WORLD_MUSIC_WATCH_COUNTRIES <- c(
  "us", "gb", "ca", "au", "ie", "nz",
  "br", "pt",
  "mx", "ar", "co", "es", "cl", "pe",
  "de", "at", "ch",
  "fr", "be",
  "it", "nl", "se", "no", "dk", "fi",
  "pl", "cz", "hu", "ro",
  "tr", "gr",
  "jp", "kr", "tw", "hk",
  "id", "ph", "th", "vn", "my", "sg",
  "in",
  "za", "ng",
  "ae", "sa", "eg", "il",
  "ec", "uy", "py", "bo", "do", "gt", "cr"
)
