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
  request_timeout_seconds = 30L,
  period_refresh_rounds = 2L,
  period_refresh_wait_seconds = 15
)

# Explicit exception approved for the frozen India source. All other configured
# markets remain mandatory; this is not a generic percentage threshold.
CHART_COVERAGE_POLICY <- "india-stale-only-v1: require GLOBAL and all other 54 markets; exclude only structurally valid stale IN; no stale rows; restore IN automatically when current"

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

classify_fetch_error <- function(status_code = NA_integer_) {
  if (is.na(status_code)) return("temporary_network")
  if (status_code %in% c(404L, 410L)) return("source_unavailable")
  if (status_code %in% c(408L, 429L) || status_code >= 500L) return("temporary_network")
  "http_error"
}

request_chart <- function(url, timeout_seconds) {
  curl::curl_fetch_memory(url, handle = curl::new_handle(
    timeout = timeout_seconds, connecttimeout = timeout_seconds,
    useragent = "MusicCharts.world validation",
    httpheader = c("Cache-Control" = "no-cache")
  ))
}

fetch_html_with_retry <- function(url,
                                  attempts = CHART_VALIDATION$fetch_attempts,
                                  wait_seconds = CHART_VALIDATION$retry_wait_seconds,
                                  timeout_seconds = CHART_VALIDATION$request_timeout_seconds,
                                  request = request_chart, sleep = Sys.sleep,
                                  on_attempt = function(history) NULL) {
  history <- list()
  for (attempt in seq_len(attempts)) {
    history[[attempt]] <- list(attempt = attempt, source_url = url,
                              failure_type = "in_progress", error = "Request has not completed.")
    on_attempt(history)
    response <- tryCatch(request(url, timeout_seconds), error = identity)
    status_code <- if (inherits(response, "error")) NA_integer_ else response$status_code
    failure_type <- NULL
    error <- NULL
    page <- NULL
    if (inherits(response, "error")) {
      error <- conditionMessage(response)
      failure_type <- classify_fetch_error()
    } else if (status_code != 200L) {
      error <- sprintf("HTTP %d", status_code)
      failure_type <- classify_fetch_error(status_code)
    } else {
      page <- tryCatch(read_html(response$content), error = identity)
      if (inherits(page, "error")) {
        error <- conditionMessage(page)
        failure_type <- "page_structure"
        page <- NULL
      }
    }
    history[[attempt]] <- list(
      attempt = attempt, source_url = url,
      fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      http_status = status_code, failure_type = failure_type, error = error
    )
    on_attempt(history)
    if (!is.null(page) || !identical(failure_type, "temporary_network")) break
    if (attempt < attempts) sleep(wait_seconds * 2^(attempt - 1L))
  }
  list(page = page, attempts = length(history), error = error,
       failure_type = failure_type, attempt_history = history)
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
                                pause_seconds = 0,
                                on_attempt = function(history) NULL) {
  source_url <- kworb_chart_url(country_code)
  fetched_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  fetched <- fetch_html_with_retry(source_url, on_attempt = on_attempt)

  finish <- function(status, period = as.Date(NA), data = tibble(),
                     errors = character(), warnings = character(),
                     failure_type = NULL, parser_failure_rate = NULL) {
    history <- fetched$attempt_history
    if (length(history)) {
      history[[length(history)]]$chart_period <- as.character(period)
      history[[length(history)]]$failure_type <- failure_type
      history[[length(history)]]$error <- paste(errors, collapse = "; ")
    }
    list(country_code = toupper(country_code), status = status,
         source_url = source_url, chart_period = period, fetched_at = fetched_at,
         attempts = fetched$attempts, attempt_history = history, data = data,
         errors = errors, warnings = warnings, failure_type = failure_type,
         parser_failure_rate = parser_failure_rate)
  }

  if (is.null(fetched$page)) {
    return(finish(
      if (identical(fetched$failure_type, "source_unavailable")) "unavailable" else "failed",
      errors = fetched$error, failure_type = fetched$failure_type
    ))
  }

  tryCatch({
    chart_period <- tryCatch(
      extract_kworb_chart_period(fetched$page),
      error = function(e) e
    )
    if (inherits(chart_period, "error")) {
      return(finish("failed", errors = conditionMessage(chart_period),
                    failure_type = "page_structure"))
    }

    table_node <- html_element(fetched$page, "table.sortable")
    rows <- if (inherits(table_node, "xml_missing")) {
      list()
    } else {
      html_elements(table_node, "tr")
    }
    if (length(rows) < 2L) {
      return(finish("failed", chart_period, errors = "No chart table rows were found.",
                    failure_type = "page_structure"))
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
    if (!nrow(parsed)) {
      return(finish("failed", chart_period, errors = "No source rows could be parsed.",
                    failure_type = "page_structure", parser_failure_rate = 1))
    }
    validation <- validate_chart(
      parsed,
      raw_row_count = length(rows) - 1L,
      parse_failure_count = parse_failure_count,
      top_n = top_n
    )

    if (pause_seconds > 0) Sys.sleep(pause_seconds)

    finish(
      if (validation$valid) "success" else "failed",
      chart_period,
      data = parsed |>
        filter(rank <= top_n) |>
        arrange(rank),
      errors = validation$errors,
      warnings = validation$warnings,
      failure_type = if (validation$valid) NULL else if (parse_failure_count > 0L) "page_structure" else "data_integrity",
      parser_failure_rate = validation$parser_failure_rate
    )
  }, error = function(e) finish("failed", errors = conditionMessage(e),
                               failure_type = "unexpected_error"))
}

pending_chart_result <- function(code) {
  list(country_code = toupper(code), status = "pending",
       source_url = kworb_chart_url(code), chart_period = as.Date(NA),
       fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
       attempts = 0L, attempt_history = list(), data = tibble(),
       failure_type = "not_completed", errors = "Fetch has not completed.",
       warnings = character())
}

fetch_chart_run <- function(country_codes,
                            top_n = CHART_VALIDATION$displayed_depth,
                            pause_seconds = 0.5,
                            fail_on_error = TRUE,
                            refresh_rounds = CHART_VALIDATION$period_refresh_rounds,
                            refresh_wait = CHART_VALIDATION$period_refresh_wait_seconds,
                            checkpoint = function(run) NULL,
                            fetch_country = fetch_kworb_country, sleep = Sys.sleep) {
  codes <- toupper(country_codes)
  all_results <- setNames(lapply(c("GLOBAL", codes), pending_chart_result), c("GLOBAL", codes))
  snapshot <- function(complete = FALSE) {
    run <- summarize_chart_run(all_results$GLOBAL, all_results[codes], codes, complete)
    checkpoint(run)
    run
  }
  fetch_one <- function(code) {
    previous <- all_results[[code]]
    message("Fetching ", code, " from ", previous$source_url, "...")
    on_attempt <- function(history) {
      pending <- previous
      pending$status <- "pending"
      pending$failure_type <- "not_completed"
      pending$errors <- "Source fetch/parse has not completed; see attempt history."
      pending$attempts <- previous$attempts + length(history)
      pending$attempt_history <- c(previous$attempt_history, history)
      all_results[[code]] <<- pending
      snapshot()
    }
    result <- tryCatch(fetch_country(code, top_n = top_n, pause_seconds = pause_seconds,
                                    on_attempt = on_attempt),
      error = function(e) {
        result <- all_results[[code]]
        result$attempts <- result$attempts - previous$attempts
        result$attempt_history <- tail(result$attempt_history, result$attempts)
        result$status <- "failed"
        result$failure_type <- "unexpected_error"
        result$errors <- conditionMessage(e)
        result
      })
    result$attempts <- previous$attempts + result$attempts
    result$attempt_history <- c(previous$attempt_history, result$attempt_history)
    if (length(result$attempt_history)) {
      for (i in seq_along(result$attempt_history)) result$attempt_history[[i]]$attempt <- i
    }
    all_results[[code]] <<- result
    message(sprintf("%s: %s; period=%s; attempts=%d; %s",
                    code, result$status, result$chart_period, result$attempts,
                    paste(result$errors, collapse = "; ")))
    snapshot()
  }
  snapshot()
  for (code in names(all_results)) fetch_one(code)

  # Refetch live pages only. Never backdate the worldwide chart or reuse an old
  # market to make a mixed-period release look complete.
  mismatched <- function() {
    global <- all_results$GLOBAL
    if (global$status != "success") return(character())
    codes[vapply(all_results[codes], function(x) {
      x$status == "success" && !is.na(x$chart_period) && x$chart_period != global$chart_period
    }, logical(1))]
  }
  for (round in seq_len(refresh_rounds)) {
    if (!length(mismatched())) break
    sleep(refresh_wait)
    fetch_one("GLOBAL")
    for (code in mismatched()) fetch_one(code)
  }
  run <- snapshot(complete = TRUE)
  if (fail_on_error && run$validation_status != "pass") {
    stop(paste(run$critical_failures, collapse = " "), call. = FALSE)
  }
  run
}

summarize_chart_run <- function(global, results, country_codes, complete = TRUE) {
  excluded <- character()
  if (global$status == "success") {
    for (code in names(results)) {
      result <- results[[code]]
      if (result$status == "success" && result$chart_period != global$chart_period) {
        result$status <- "failed"
        result$failure_type <- if (result$chart_period < global$chart_period) "stale_publication" else "period_ahead"
        result$errors <- sprintf("Observed period %s; required worldwide period %s (%d days difference).",
                                 result$chart_period, global$chart_period,
                                 as.integer(result$chart_period - global$chart_period))
        if (code == "IN" && result$failure_type == "stale_publication") {
          result$status <- "unavailable"
          result$observed_row_count <- nrow(result$data)
          result$data <- result$data[0, , drop = FALSE]
          result$warnings <- c(result$warnings, paste0(
            "India unavailable for ", global$chart_period, "; source still shows ",
            result$chart_period, ". Excluded from all calculations and rankings; no stale chart reused."))
          excluded <- c(excluded, code)
        }
        results[[code]] <- result
      }
    }
  }

  failed <- names(results)[vapply(results, function(x) x$status == "failed", logical(1))]
  unavailable <- names(results)[vapply(results, function(x) x$status == "unavailable", logical(1))]
  successful <- names(results)[vapply(results, function(x) x$status == "success", logical(1))]

  critical_failures <- character()
  if (global$status != "success") {
    critical_failures <- c(
      critical_failures,
      market_failure_detail(global)
    )
  }
  if (length(failed) > 0L) {
    critical_failures <- c(
      critical_failures,
      vapply(results[failed], market_failure_detail, character(1))
    )
  }
  blocking_unavailable <- setdiff(unavailable, excluded)
  if (length(blocking_unavailable)) {
    critical_failures <- c(critical_failures, vapply(results[blocking_unavailable], market_failure_detail, character(1)))
  }
  if (!complete || length(successful) + length(excluded) != length(country_codes)) {
    critical_failures <- c(critical_failures, sprintf(
      "Required coverage not met: %d/%d national markets current. Only structurally valid stale India may be excluded.",
      length(successful), length(country_codes)))
  }

  warnings <- c(
    unlist(lapply(c(list(GLOBAL = global), results), `[[`, "warnings"), use.names = FALSE),
    if (length(unavailable) > 0L) {
      paste0("Markets unavailable for this chart period: ", paste(unavailable, collapse = ", "))
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
    global_result = global,
    complete = complete,
    coverage_policy = CHART_COVERAGE_POLICY,
    excluded_markets = excluded,
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

  run
}

market_failure_detail <- function(result) {
  sprintf("%s [%s] %s; attempts=%d: %s", result$country_code,
          if (is.null(result$failure_type)) result$status else result$failure_type,
          result$source_url, result$attempts, paste(result$errors, collapse = "; "))
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
