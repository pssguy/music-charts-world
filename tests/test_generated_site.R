library(rvest)
library(jsonlite)

site_dir <- Sys.getenv("MUSICCHARTS_SITE_DIR", unset = "_site")
validated_run_path <- trimws(Sys.getenv("MUSICCHARTS_VALIDATED_RUN"))
chart_run <- if (nzchar(validated_run_path)) readRDS(validated_run_path) else NULL

required_files <- c(
  "index.html",
  "world-music-watch.css",
  "CNAME",
  "robots.txt",
  "sitemap.xml",
  "deployment-manifest.json"
)
stopifnot(all(file.exists(file.path(site_dir, required_files))))

page <- read_html(file.path(site_dir, "index.html"))
one <- function(selector, attribute = NULL) {
  nodes <- html_elements(page, selector)
  stopifnot(length(nodes) == 1L)
  if (is.null(attribute)) html_text2(nodes) else html_attr(nodes, attribute)
}

stopifnot(grepl("MusicCharts.world", one("title"), fixed = TRUE))
stopifnot(nzchar(one('meta[name="description"]', "content")))
stopifnot(identical(one('link[rel="canonical"]', "href"), "https://musiccharts.world/"))
stopifnot(nzchar(one('meta[property="og:title"]', "content")))
stopifnot(nzchar(one('meta[property="og:description"]', "content")))
stopifnot(nzchar(one('meta[name="twitter:card"]', "content")))
stopifnot(length(html_elements(page, "h1")) == 1L)
stopifnot(length(html_elements(page, 'meta[http-equiv="refresh"]')) == 0L)

visible_page <- read_html(file.path(site_dir, "index.html"))
xml2::xml_remove(html_elements(visible_page, "script, style"))
body_text <- html_text2(html_element(visible_page, "body"))
stopifnot(grepl("Chart week ending", body_text, fixed = TRUE))
stopifnot(grepl("not affiliated with or endorsed by Spotify", body_text, fixed = TRUE))
stopifnot(grepl("Method.", body_text, fixed = TRUE))
stopifnot(grepl("Source and positioning.", body_text, fixed = TRUE))
stopifnot(grepl("Publication metadata.", body_text, fixed = TRUE))
stopifnot(grepl("Chart period:", body_text, fixed = TRUE))
stopifnot(grepl("Data fetched at:", body_text, fixed = TRUE))
stopifnot(grepl("Site deployed at:", body_text, fixed = TRUE))
stopifnot(grepl("Git commit:", body_text, fixed = TRUE))
stopifnot(grepl("GitHub Actions run:", body_text, fixed = TRUE))
stopifnot(!grepl("MUSICCHARTS_TEST_MARKETS", body_text, fixed = TRUE))

assert_no_match <- function(values, pattern, label) {
  values <- values[!is.na(values) & nzchar(values)]
  matches <- unique(values[grepl(pattern, values, perl = TRUE)])
  if (length(matches) > 0L) {
    fragments <- unique(unlist(regmatches(
      matches,
      gregexpr(pattern, matches, perl = TRUE)
    )))
    stop(label, ": ", paste(head(fragments, 10L), collapse = " | "), call. = FALSE)
  }
}

# Loopback hosts are forbidden only where a value represents a production URL.
# Quarto's own inline localhostRegex implementation is code, not a published URL.
loopback_pattern <- "(?i)(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1\\])"
stopifnot(
  grepl(loopback_pattern, "http://localhost:8000/preview", perl = TRUE),
  grepl(loopback_pattern, "http://127.0.0.1/site", perl = TRUE),
  !grepl(loopback_pattern, "https://musiccharts.world/", perl = TRUE)
)
published_urls <- c(
  html_attr(html_elements(page, "a[href], link[href]"), "href"),
  html_attr(html_elements(page, "script[src], iframe[src], img[src], source[src]"), "src"),
  html_attr(html_elements(page, "form[action]"), "action"),
  html_attr(html_elements(page, "video[poster]"), "poster"),
  html_attr(html_elements(page, "object[data]"), "data"),
  html_attr(html_elements(page, 'meta[property="og:url"], meta[name="twitter:url"], meta[itemprop="url"]'), "content")
)
assert_no_match(published_urls, loopback_pattern, "Loopback host leaked into a published URL")

# Placeholder checks target static/template material and explicit markers. Chart
# panels and data cards are removed so ordinary international titles containing
# words such as "Todo" remain valid content.
placeholder_pattern <- paste(c(
  "(?i)\\bTODO\\s*:",
  "(?i)\\bFIXME\\s*:",
  "(?i)\\bXXX\\s*:",
  "(?i)\\bTBD\\b",
  "(?i)LOREM\\s+IPSUM",
  "(?i)EXAMPLE\\.COM",
  "(?i)YOUR_[A-Z0-9_]+_HERE",
  "(?i)REPLACE[_ -]ME",
  "(?i)__PLACEHOLDER__",
  "\\{\\{[^{}]+\\}\\}",
  "<%=?[^%]+%>",
  "(?i)\\[(?:TODO|FIXME|TBD|PLACEHOLDER)\\]"
), collapse = "|")
stopifnot(
  grepl(placeholder_pattern, "TODO: replace this block", perl = TRUE),
  grepl(placeholder_pattern, "FIXME: temporary copy", perl = TRUE),
  !grepl(placeholder_pattern, "Todo Lo Fue", perl = TRUE),
  !grepl(placeholder_pattern, "Peão Todo Tatuado", perl = TRUE)
)

static_page <- read_html(file.path(site_dir, "index.html"))
xml2::xml_remove(html_elements(static_page, "script, style, .country-panel, .outlier"))
static_text <- html_text2(html_element(static_page, "body"))
static_attributes <- unname(unlist(lapply(html_elements(static_page, "*"), xml2::xml_attrs)))
html_comments <- xml2::xml_text(xml2::xml_find_all(page, "//comment()"))
template_files <- c("world-music-watch.qmd", "world-music-watch.css")
template_files <- template_files[file.exists(template_files)]
template_source <- unlist(lapply(template_files, readLines, warn = FALSE), use.names = FALSE)
assert_no_match(
  c(static_text, static_attributes, html_comments, template_source),
  placeholder_pattern,
  "Development placeholder leaked into generated output"
)

if (!is.null(chart_run)) {
  source("R/fetch_charts.R")
  stopifnot(identical(chart_run$validation_status, "pass"))
  configured_count <- length(chart_run$configured_markets)
  successful_count <- length(chart_run$successful_markets)
  unavailable_count <- length(chart_run$unavailable_markets)
  expected_period <- format(as.Date(chart_run$chart_period), "%d %B %Y")

  expected_market_count <- suppressWarnings(as.integer(Sys.getenv("MUSICCHARTS_EXPECTED_MARKETS")))
  if (is.na(expected_market_count)) expected_market_count <- length(WORLD_MUSIC_WATCH_COUNTRIES)
  stopifnot(configured_count == expected_market_count)
  expected_display_period <- paste(
    format(as.Date(chart_run$chart_period), "%B"),
    as.integer(format(as.Date(chart_run$chart_period), "%d")),
    format(as.Date(chart_run$chart_period), "%Y")
  )
  stopifnot(grepl(paste0("Chart week ending ", expected_display_period), body_text, fixed = TRUE))
  stopifnot(length(chart_run$failed_markets) == 0L)
  stopifnot(grepl(
    sprintf("Coverage for this issue: %d of %d configured markets loaded; %d unavailable",
            successful_count, configured_count, unavailable_count),
    body_text,
    fixed = TRUE
  ))
  if (unavailable_count == 0L) {
    stopifnot(grepl("No configured markets were unavailable", body_text, fixed = TRUE))
  } else {
    stopifnot(grepl("Unavailable markets:", body_text, fixed = TRUE))
  }
} else {
  configured_count <- as.integer(Sys.getenv("MUSICCHARTS_EXPECTED_MARKETS", unset = "3"))
  successful_count <- configured_count
}

track_buttons <- html_elements(page, "button.track-row")
stopifnot(length(track_buttons) == (successful_count + 1L) * 50L)
stopifnot(all(html_attr(track_buttons, "type") == "button"))
stopifnot(all(nzchar(html_attr(track_buttons, "aria-label"))))
stopifnot(all(html_attr(track_buttons, "aria-pressed") %in% c("true", "false")))
stopifnot(length(html_elements(page, "li.track-row")) == 0L)
stopifnot(length(html_elements(page, "iframe:not([title])")) == 0L)

options <- html_elements(page, "#country-select option")
panels <- html_elements(page, ".country-panel")
stopifnot(length(options) == successful_count + 1L)
stopifnot(length(panels) == successful_count + 1L)
if (!is.null(chart_run)) {
  stopifnot(setequal(html_attr(options, "value"), c("GLOBAL", chart_run$successful_markets)))
  stopifnot(setequal(html_attr(panels, "id"), paste0("panel-", c("GLOBAL", chart_run$successful_markets))))
}
panel_button_counts <- vapply(
  panels,
  function(panel) length(html_elements(panel, "button.track-row")),
  integer(1)
)
stopifnot(all(panel_button_counts == 50L))

local_assets <- unique(c(
  html_attr(html_elements(page, 'link[rel="stylesheet"][href]'), "href"),
  html_attr(html_elements(page, "script[src]"), "src")
))
local_assets <- local_assets[!is.na(local_assets) & !grepl("^(https?:)?//|^data:", local_assets)]
local_assets <- sub("[?#].*$", "", local_assets)
local_assets <- sub("^/", "", local_assets)
stopifnot(all(file.exists(file.path(site_dir, local_assets))))

robots <- paste(readLines(file.path(site_dir, "robots.txt"), warn = FALSE), collapse = "\n")
stopifnot(grepl("https://musiccharts.world/sitemap.xml", robots, fixed = TRUE))

manifest <- read_json(file.path(site_dir, "deployment-manifest.json"), simplifyVector = FALSE)
manifest_required <- c(
  "schema_version", "chart_period", "fetched_at", "source_url", "configured_markets",
  "successful_markets", "failed_markets", "unavailable_markets", "market_statuses",
  "worldwide_row_count", "site_bytes", "warning_count", "warnings", "validation", "commit", "workflow",
  "run_id", "run_attempt", "run_url", "rendered_at", "deployed_at"
)
stopifnot(all(manifest_required %in% names(manifest)))
stopifnot(identical(manifest$validation$status, "pass"))
stopifnot(!any(c("charts", "tracks", "chart_rows") %in% names(manifest)))
assert_no_match(
  jsonlite::toJSON(manifest, auto_unbox = TRUE, null = "null"),
  loopback_pattern,
  "Loopback host leaked into deployment metadata"
)

cat("generated-site tests passed\n")
