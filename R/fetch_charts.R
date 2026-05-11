# R/fetch_charts.R
# ---------------------------------------------------------------
# Pulls weekly Spotify Top 200 per country from kworb.net,
# which aggregates Spotify's official charts and exposes them as
# clean static HTML tables. Each track row links to a kworb track
# page whose URL contains the Spotify track ID — which is what we
# need for the embedded players.
#
# kworb is updated daily, has been running since ~2013, and explicitly
# encourages scraping ("incredibly easy to scrape and puts practically
# 0 stress on their servers" — DataGoblin's repo, citing kworb).
# ---------------------------------------------------------------

library(rvest)
library(dplyr)
library(stringr)
library(purrr)
library(tibble)

#' Fetch one country's weekly Spotify chart from kworb
#'
#' @param country_code ISO 3166-1 alpha-2, lowercase (e.g. "us", "gb")
#' @param top_n How many positions to keep (default 50)
#' @return tibble with rank, title, artist, track_id, track_url
fetch_kworb_country <- function(country_code, top_n = 50) {
  url <- sprintf("https://kworb.net/spotify/country/%s_weekly.html",
                 tolower(country_code))

  page <- tryCatch(read_html(url), error = function(e) NULL)
  if (is.null(page)) {
    warning("Could not fetch ", country_code)
    return(NULL)
  }

  # The chart sits in the first (and main) table on the page.
  rows <- page |>
    html_element("table.sortable") |>
    html_elements("tr")

  if (length(rows) < 2) {
    warning("No table rows found for ", country_code)
    return(NULL)
  }

  # Each data row has separate <a> links for artist and track.
  # Cell 1: rank, Cell 2: position change ("+2", "-5", "=", "NEW", "RE")
  # Cell 3 contains: <a href="../artist/{id}.html">Artist</a> - <a href="../track/{id}.html">Title</a>
  parsed <- map_dfr(rows[-1], function(row) {
    cells <- html_elements(row, "td")
    if (length(cells) < 2) return(NULL)

    # Position change vs last week (cell 2)
    change <- html_text(cells[2], trim = TRUE)

    links <- html_elements(row, "a")
    hrefs <- html_attr(links, "href")

    # Find the track link (href contains "track/")
    track_idx <- which(str_detect(hrefs, "track/"))
    if (length(track_idx) == 0) return(NULL)

    track_href <- hrefs[track_idx[1]]
    track_id   <- str_match(track_href, "track/([A-Za-z0-9]+)\\.html")[, 2]
    title      <- html_text(links[track_idx[1]], trim = TRUE)

    # Find the artist link (href contains "artist/")
    artist_idx <- which(str_detect(hrefs, "artist/"))
    artist     <- if (length(artist_idx) > 0) {
      html_text(links[artist_idx[1]], trim = TRUE)
    } else {
      NA_character_
    }

    tibble(
      track_id  = track_id,
      title     = title,
      artist    = artist,
      change    = change,
      track_url = paste0("https://open.spotify.com/track/", track_id)
    )
  })

  parsed |>
    filter(!is.na(track_id)) |>
    mutate(rank = row_number(),
           country_code = toupper(country_code)) |>
    head(top_n) |>
    select(country_code, rank, title, artist, change, track_id, track_url)
}

#' Fetch a list of countries, with polite pacing
fetch_all_countries <- function(country_codes, top_n = 50,
                                 pause_seconds = 0.5) {
  map_dfr(country_codes, function(cc) {
    message("Fetching ", cc, "...")
    res <- fetch_kworb_country(cc, top_n)
    Sys.sleep(pause_seconds)
    res
  })
}

# ISO codes used by kworb. These match the URL slugs on
# kworb.net/spotify/country/{code}_weekly.html
WORLD_MUSIC_WATCH_COUNTRIES <- c(
  "us", "gb", "ca", "au", "ie", "nz",            # Anglophone
  "br", "pt",                                    # Lusophone
  "mx", "ar", "co", "es", "cl", "pe",            # Hispanophone
  "de", "at", "ch",                              # Germanophone
  "fr", "be",                                    # Francophone
  "it", "nl", "se", "no", "dk", "fi",            # Other Western Europe
  "pl", "cz", "hu", "ro",                        # Central/Eastern Europe
  "tr", "gr",
  "jp", "kr", "tw", "hk",                        # East Asia
  "id", "ph", "th", "vn", "my", "sg",            # SE Asia
  "in",                                          # South Asia
  "za", "ng",                                    # Africa
  "ae", "sa", "eg", "il",                        # Middle East
  "ec", "uy", "py", "bo", "do", "gt", "cr"       # More Latin America
)
