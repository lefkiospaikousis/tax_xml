# ============================================================================
# OECD DPI XML Generator - shared business logic
# ============================================================================
# Every function used to clean vendor data and build the DPI XML lives here,
# shared between the CLI script (xml.R) and the Shiny app (app.R), so the two
# entry points can never drift on the business rules (entity classification,
# TIN/DOB/address fallbacks, DocRefId/BirthPlace/ResCountryCode rules, etc).
#
# This file defines functions only - sourcing it has no side effects.
# ============================================================================

library(readxl)
library(dplyr)
library(stringr)
library(xml2)
library(uuid)

# ============================================================================
# FALLBACK LOGGING
# ============================================================================
# A mutable, environment-based accumulator passed as an extra trailing `log`
# parameter through the XML-building functions. Every existing call site
# (xml.R) omits it entirely and every log_fallback() call becomes a no-op, so
# this is purely additive - no behavior change for the CLI script.

#' Create a new fallback log accumulator
new_fallback_log <- function() {
  env <- new.env(parent = emptyenv())
  env$rows <- vector("list", 0)
  env
}

#' Record a fallback event. No-op if log is NULL.
log_fallback <- function(log, producer, field, message) {
  if (is.null(log)) return(invisible(NULL))
  log$rows[[length(log$rows) + 1]] <- data.frame(
    producer = if (is.null(producer) || is.na(producer)) "(unknown producer)" else producer,
    field    = field,
    message  = message,
    stringsAsFactors = FALSE
  )
  invisible(NULL)
}

#' Collapse a fallback log into a data frame (producer, field, message)
fallback_log_to_df <- function(log) {
  if (is.null(log) || length(log$rows) == 0) {
    return(data.frame(producer = character(), field = character(),
                       message = character(), stringsAsFactors = FALSE))
  }
  dplyr::bind_rows(log$rows)
}

# ============================================================================
# SOURCE DATA VALIDATION
# ============================================================================

#' Columns required for the pipeline to run at all
REQUIRED_SOURCE_COLUMNS <- c(
  "PRODUCER", "ADDRESS", "EMAIL ADDRESS", "COMPANY REGISTRATION NUMBER",
  "ID", "TAX NUMBER", "COUNTRY TAX RESIDENCE", "DATE OF BIRTH", "IBAN", "BANK",
  paste0("Q", rep(1:4, each = 3), c("_INCOME", "_TRANSACTIONS", "_FEES"))
)

#' Check that an uploaded/loaded data frame has the columns this pipeline needs
#' @return list(ok, missing_columns, n_rows)
validate_source_columns <- function(df) {
  missing <- setdiff(REQUIRED_SOURCE_COLUMNS, names(df))
  list(
    ok = length(missing) == 0 && nrow(df) >= 1,
    missing_columns = missing,
    n_rows = nrow(df)
  )
}

# ============================================================================
# INGESTION / CLEANING
# ============================================================================

#' Parse a per-quarter amount column that mixes numeric, "-", blank and decimal-string values
parse_amount <- function(x) {
  x <- as.character(x)
  x[x %in% c("-", "")] <- NA
  x <- str_remove_all(x, "[^0-9\\.]")
  out <- suppressWarnings(as.numeric(x))
  ifelse(is.na(out), 0, out)
}

#' Parse a Date-of-Birth value that may arrive as a native Date/POSIXct,
#' an Excel serial number stored as text (e.g. "26539"), or an ISO date string
parse_dob <- function(x) {
  if (inherits(x, "Date") || inherits(x, "POSIXct")) {
    return(format(as.Date(x), "%Y-%m-%d"))
  }

  x <- as.character(x)
  x[x %in% c("N/A", "NA", "")] <- NA

  parsed <- rep(NA_character_, length(x))

  is_serial <- !is.na(x) & grepl("^[0-9]+$", x)
  parsed[is_serial] <- format(as.Date(as.numeric(x[is_serial]), origin = "1899-12-30"), "%Y-%m-%d")

  is_text_date <- !is.na(x) & !is_serial
  parsed[is_text_date] <- vapply(x[is_text_date], function(v) {
    d <- tryCatch(as.Date(v), error = function(e) NA)
    if (is.na(d)) NA_character_ else format(d, "%Y-%m-%d")
  }, character(1))

  parsed
}

#' Clean + reshape a raw vendors data frame (as read by readxl) into the
#' snake_case, per-quarter-numeric shape the XML builders expect, and filter
#' to rows with reportable annual income. Identical to xml.R's previous
#' inline pipeline - extracted so both entry points share exactly one copy.
clean_vendor_data <- function(raw) {
  vendors <- raw |>
    mutate(
      across(c(Q1_INCOME, Q2_INCOME, Q3_INCOME, Q4_INCOME,
               Q1_FEES, Q2_FEES, Q3_FEES, Q4_FEES,
               Q1_TRANSACTIONS, Q2_TRANSACTIONS, Q3_TRANSACTIONS, Q4_TRANSACTIONS),
             parse_amount),
      iban       = str_remove_all(IBAN, "\\s+"),
      dob        = parse_dob(`DATE OF BIRTH`),
      id_number  = ifelse(is.na(ID), NA_character_, format(ID, scientific = FALSE, trim = TRUE))
    ) |>

    select(
      producer = PRODUCER,
      address = ADDRESS,
      email = `EMAIL ADDRESS`,
      company_reg = `COMPANY REGISTRATION NUMBER`,
      id_number,
      tax_number = `TAX NUMBER`,
      country_tax = `COUNTRY TAX RESIDENCE`,
      dob,
      iban,
      bank = BANK,
      income_q1 = Q1_INCOME, income_q2 = Q2_INCOME, income_q3 = Q3_INCOME, income_q4 = Q4_INCOME,
      fees_q1 = Q1_FEES, fees_q2 = Q2_FEES, fees_q3 = Q3_FEES, fees_q4 = Q4_FEES,
      trans_q1 = Q1_TRANSACTIONS, trans_q2 = Q2_TRANSACTIONS, trans_q3 = Q3_TRANSACTIONS, trans_q4 = Q4_TRANSACTIONS
    )

  # keep only vendors with reportable annual income
  vendors <- vendors |>
    mutate(annual_income = income_q1 + income_q2 + income_q3 + income_q4) |>
    filter(annual_income > 0)

  vendors
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

#' Generate Document Reference ID
#' Format: {CountryCode}{Year}{UUID}
generate_doc_ref_id <- function(country, year) {
  paste0(country, year, uuid::UUIDgenerate())
}

#' Generate Message Reference ID
#' Format: {TransmittingCountry}{Year}{ReceivingCountry}-{UUID}
generate_message_ref_id <- function(transmitting, receiving, year) {
  paste0(transmitting, year, receiving, "-", uuid::UUIDgenerate())
}

#' Check if vendor is an entity (company) vs individual
#' Returns TRUE for companies (HE/ΗΕ prefix, in any Latin/Greek letter mix), FALSE for individuals
#' Built from explicit Unicode code points (not literal Greek characters) so the
#' regex is not corrupted by non-UTF-8 native locales/codepages when the script is sourced.
is_entity <- function(company_reg) {

  if (is.na(company_reg) || company_reg == "N/A" || company_reg == "") {
    return(FALSE)
  }
  greek_eta <- intToUtf8(0x0397)      # Η, Greek capital Eta - looks like Latin H
  greek_epsilon <- intToUtf8(0x0395)  # Ε, Greek capital Epsilon - looks like Latin E
  he_regex <- paste0("^[H", greek_eta, "][E", greek_epsilon, "]\\s*\\d+$")
  grepl(he_regex, company_reg, ignore.case = TRUE)
}

#' Clean IBAN by removing spaces
clean_iban <- function(iban) {
  gsub("\\s+", "", iban)
}

#' Map country name to ISO 2-letter code
map_country_name_to_code <- function(country_name) {

  original_name <- country_name
  country_name <- countrycode::countryname(country_name)

  code <- countrycode::countrycode(country_name, 'country.name', destination = 'iso2c')

  return(code)

}

#' Parse the DPI XSD's own CountryCode_Type enumeration into a code/name lookup,
#' for driving strict country dropdowns instead of free text.
#' @param xsd_path path to isodpitypes_v1.0.xsd
get_dpi_country_codes <- function(xsd_path) {
  doc <- read_xml(xsd_path)
  ns  <- xml_ns(doc)
  type_node  <- xml_find_first(doc, "//xsd:simpleType[@name='CountryCode_Type']", ns)
  enum_nodes <- xml_find_all(type_node, ".//xsd:enumeration", ns)
  data.frame(
    code = xml_attr(enum_nodes, "value"),
    name = xml_text(xml_find_first(enum_nodes, ".//xsd:documentation", ns)),
    stringsAsFactors = FALSE
  )
}

#' Parse full name into first, middle, last parts
parse_name_parts <- function(full_name) {
  parts <- str_split(str_trim(full_name), "\\s+")[[1]]
  n_parts <- length(parts)

  if (n_parts == 1) {
    return(list(first = parts[1], middle = NA, last = parts[1]))
  } else if (n_parts == 2) {
    return(list(first = parts[1], middle = NA, last = parts[2]))
  } else {
    return(list(
      first = parts[1],
      middle = paste(parts[2:(n_parts-1)], collapse = " "),
      last = parts[n_parts]
    ))
  }
}

#' Clean and normalize address text
clean_address <- function(address_text) {
  if (is.na(address_text) || address_text == "N/A" || address_text == "") {
    return(NA)
  }
  # Remove quotes, newlines, and extra spaces
  clean <- gsub('[\"\n\r]', ' ', address_text)
  clean <- gsub('\\s+', ' ', clean)
  str_trim(clean)
}

# ============================================================================
# XML BUILDING FUNCTIONS
# ============================================================================

#' Add Platform Operator section to XML
add_platform_operator <- function(parent, po, year, ns_dpi, ns_stf) {

  po_node <- xml_add_child(parent, "dpi:PlatformOperator")

  xml_add_child(po_node, "dpi:ResCountryCode", po$country_code)

  # TIN with issuedBy attribute
  tin_node <- xml_add_child(po_node, "dpi:TIN", po$tin)
  xml_set_attr(tin_node, "issuedBy", po$country_code)

  xml_add_child(po_node, "dpi:VAT", po$vat)
  xml_add_child(po_node, "dpi:Name", po$name)
  xml_add_child(po_node, "dpi:PlatformBusinessName", po$business_name)

  # Address block
  address_node <- xml_add_child(po_node, "dpi:Address")
  xml_set_attr(address_node, "legalAddressType", "OECD304")

  xml_add_child(address_node, "dpi:CountryCode", po$country_code)

  address_fix <- xml_add_child(address_node, "dpi:AddressFix")
  xml_add_child(address_fix, "dpi:Street", po$street)
  xml_add_child(address_fix, "dpi:DistrictName", po$district)
  xml_add_child(address_fix, "dpi:PostCode", po$postcode)
  xml_add_child(address_fix, "dpi:City", po$city)

  # Nexus and AssumedReporting
  xml_add_child(po_node, "dpi:Nexus", "RPONEX1")
  xml_add_child(po_node, "dpi:AssumedReporting", "false")

  # DocSpec
  doc_spec <- xml_add_child(po_node, "dpi:DocSpec")
  xml_add_child(doc_spec, "stf:DocTypeIndic", "OECD1")
  xml_add_child(doc_spec, "stf:DocRefId", generate_doc_ref_id(po$country_code, year))
}

#' Add Financial Identifier (IBAN) to XML
add_financial_identifier <- function(parent, iban) {
  if (is.na(iban) || iban == "" || iban == "N/A") return()

  fin_id <- xml_add_child(parent, "dpi:FinancialIdentifier")

  clean_iban_val <- clean_iban(iban)
  id_node <- xml_add_child(fin_id, "dpi:Identifier", clean_iban_val)
  xml_set_attr(id_node, "AccountNumberType", "IBAN")
}

#' Add Address to XML (using AddressFree format)
#' @param producer producer name, used only for fallback-log attribution
#' @param log optional fallback log (see new_fallback_log())
add_address <- function(parent, address_text, country_code, producer = NA_character_, log = NULL) {
  address_node <- xml_add_child(parent, "dpi:Address")
  xml_set_attr(address_node, "legalAddressType", "OECD301")

  xml_add_child(address_node, "dpi:CountryCode", country_code)

  cleaned <- clean_address(address_text)
  if (is.na(cleaned)) {
    xml_add_child(address_node, "dpi:AddressFree", "Address unknown")
    log_fallback(log, producer, "address", "address missing/blank, used 'Address unknown' placeholder")
  } else {
    xml_add_child(address_node, "dpi:AddressFree", cleaned)
  }
}

#' Add Entity Seller (Company) to XML
add_entity_seller <- function(parent, vendor, country_code, log = NULL) {
  entity_seller <- xml_add_child(parent, "dpi:EntitySeller")
  standard <- xml_add_child(entity_seller, "dpi:Standard")
  ent_seller_id <- xml_add_child(standard, "dpi:EntSellerID")

  xml_add_child(ent_seller_id, "dpi:ResCountryCode", country_code)

  # TIN - use unknown="true" if not provided
  if (!is.na(vendor$tax_number) && vendor$tax_number != "" && vendor$tax_number != "N/A") {
    tin_node <- xml_add_child(ent_seller_id, "dpi:TIN", vendor$tax_number)
    xml_set_attr(tin_node, "issuedBy", country_code)
  } else {
    tin_node <- xml_add_child(ent_seller_id, "dpi:TIN")
    xml_set_attr(tin_node, "unknown", "true")
    log_fallback(log, vendor$producer, "tin", "tax number missing, TIN marked unknown")
  }

  # Company Registration Number (IN = Identification Number)
  if (!is.na(vendor$company_reg) && vendor$company_reg != "N/A") {
    # Use full registration number as-is (e.g., "HE 123456")
    in_node <- xml_add_child(ent_seller_id, "dpi:IN", vendor$company_reg)
    xml_set_attr(in_node, "issuedBy", country_code)
    xml_set_attr(in_node, "INType", "BRN")  # Business Registration Number
  }

  # Entity Name
  xml_add_child(ent_seller_id, "dpi:Name", vendor$producer)

  # Address
  add_address(ent_seller_id, vendor$address, country_code, vendor$producer, log)

  # Financial Identifier (IBAN)
  add_financial_identifier(standard, vendor$iban)
}

#' Add Individual Seller (Person) to XML
#' @param receiving_country the receiving jurisdiction's country code. Since we only ever
#'   report PersonalServices (never ImmovableProperty), the portal requires at least one
#'   ResCountryCode to equal the receiving country - added as an extra entry when the
#'   seller's real residence country differs.
#' @param placeholder_dob date string used when a seller has no DOB on file
#' @param log optional fallback log (see new_fallback_log())
add_individual_seller <- function(parent, vendor, country_code, receiving_country, placeholder_dob, log = NULL) {
  ind_seller <- xml_add_child(parent, "dpi:IndividualSeller")
  standard <- xml_add_child(ind_seller, "dpi:Standard")
  ind_seller_id <- xml_add_child(standard, "dpi:IndSellerID")

  xml_add_child(ind_seller_id, "dpi:ResCountryCode", country_code)
  if (country_code != receiving_country) {
    xml_add_child(ind_seller_id, "dpi:ResCountryCode", receiving_country)
    log_fallback(log, vendor$producer, "rescountrycode",
                 paste0("residence country '", country_code, "' differs from receiving country '",
                        receiving_country, "', added second ResCountryCode"))
  }

  # TIN - prefer TAX NUMBER, fall back to the ID column, else unknown
  tin_unknown <- FALSE
  if (!is.na(vendor$tax_number) && vendor$tax_number != "" && vendor$tax_number != "N/A") {
    tin_node <- xml_add_child(ind_seller_id, "dpi:TIN", vendor$tax_number)
    xml_set_attr(tin_node, "issuedBy", country_code)
  } else if (!is.na(vendor$id_number) && vendor$id_number != "") {
    tin_node <- xml_add_child(ind_seller_id, "dpi:TIN", vendor$id_number)
    xml_set_attr(tin_node, "issuedBy", country_code)
    log_fallback(log, vendor$producer, "tin", "tax number missing, used ID column as TIN")
  } else {
    tin_node <- xml_add_child(ind_seller_id, "dpi:TIN")
    xml_set_attr(tin_node, "unknown", "true")
    tin_unknown <- TRUE
    log_fallback(log, vendor$producer, "tin", "tax number and ID both missing, TIN marked unknown")
  }

  # VAT (placeholder - add if available in your data)
  # xml_add_child(ind_seller_id, "dpi:VAT", vendor$vat)

  # Name (parsed into parts) - FirstName, MiddleName, LastName directly under Name
  name_parts <- parse_name_parts(vendor$producer)
  name_node <- xml_add_child(ind_seller_id, "dpi:Name")

  xml_add_child(name_node, "dpi:FirstName", name_parts$first)
  if (!is.na(name_parts$middle)) {
    xml_add_child(name_node, "dpi:MiddleName", name_parts$middle)
  }
  xml_add_child(name_node, "dpi:LastName", name_parts$last)

  # Address
  add_address(ind_seller_id, vendor$address, country_code, vendor$producer, log)

  # BirthInfo (required for individuals)
  birth_info <- xml_add_child(ind_seller_id, "dpi:BirthInfo")

  # BirthDate - use provided DOB or unknown
  if (!is.na(vendor$dob) && vendor$dob != "N/A" && vendor$dob != "") {

    xml_add_child(birth_info, "dpi:BirthDate", vendor$dob)

  } else {

    xml_add_child(birth_info, "dpi:BirthDate", placeholder_dob)
    log_fallback(log, vendor$producer, "dob", paste("DOB missing, used placeholder", placeholder_dob))

  }

  # BirthPlace - required by the tax portal whenever the TIN is unknown; no real
  # birth-city/country data exists in the source, so use a filler City plus the
  # seller's own resolved residence country as CountryCode
  if (tin_unknown) {
    birth_place <- xml_add_child(birth_info, "dpi:BirthPlace")
    xml_add_child(birth_place, "dpi:City", "Unknown")
    country_info <- xml_add_child(birth_place, "dpi:CountryInfo")
    xml_add_child(country_info, "dpi:CountryCode", country_code)
    log_fallback(log, vendor$producer, "birthplace", "TIN unknown, added placeholder BirthPlace (City=Unknown)")
  }

  # Financial Identifier (IBAN)
  add_financial_identifier(standard, vendor$iban)
}

#' Add a quarterly block (e.g. Consideration/ConsQn, Fees/FeesQn) to a parent node
#' @param currency currCode to attach to each element, or NULL for elements without one (NumberOfActivities)
add_quarterly <- function(parent, block_name, tag, values, currency = "EUR") {
  block_node <- xml_add_child(parent, paste0("dpi:", block_name))
  for (q in 1:4) {
    node <- xml_add_child(block_node, paste0("dpi:", tag, "Q", q), as.character(round(values[q], 0)))
    if (!is.null(currency)) {
      xml_set_attr(node, "currCode", currency)
    }
  }
}

#' Add Relevant Activities (Income, Fees, etc.) to XML using true per-quarter amounts
add_relevant_activities <- function(parent, vendor) {
  activities_node <- xml_add_child(parent, "dpi:RelevantActivities")

  # Using PersonalServices for event-related activities
  personal_services <- xml_add_child(activities_node, "dpi:PersonalServices")

  add_quarterly(personal_services, "Consideration", "Cons",
                c(vendor$income_q1, vendor$income_q2, vendor$income_q3, vendor$income_q4))

  add_quarterly(personal_services, "NumberOfActivities", "Numb",
                c(vendor$trans_q1, vendor$trans_q2, vendor$trans_q3, vendor$trans_q4),
                currency = NULL)

  add_quarterly(personal_services, "Fees", "Fees",
                c(vendor$fees_q1, vendor$fees_q2, vendor$fees_q3, vendor$fees_q4))

  # Taxes (set to 0 - not provided in source data; block is mandatory)
  add_quarterly(personal_services, "Taxes", "Tax", c(0, 0, 0, 0))
}

#' Add a Reportable Seller to XML
#' @param sending_country the transmitting jurisdiction's country code - DocRefId must always
#'   start with this (per the OECD DPI User Guide), never the seller's own residence country
#' @param receiving_country the receiving jurisdiction's country code (passed to individual
#'   sellers, who must show it as a ResCountryCode when no immovable property is reported)
#' @param placeholder_dob date string used when a seller has no DOB on file
#' @param log optional fallback log (see new_fallback_log())
add_reportable_seller <- function(parent, vendor, year, sending_country, receiving_country, placeholder_dob, log = NULL) {

  seller_node <- xml_add_child(parent, "dpi:ReportableSeller")

  # Identity section
  identity_node <- xml_add_child(seller_node, "dpi:Identity")

  country_code <- map_country_name_to_code(vendor$country_tax)

  if (is.na(country_code)) {
    message("Could not map country '", vendor$country_tax, " of vendor ", vendor$producer, "' to an ISO code - defaulting to CY")
    log_fallback(log, vendor$producer, "country_tax",
                 paste0("country '", vendor$country_tax, "' could not be mapped to ISO code, defaulted to CY"))
    country_code <- "CY"  # Default to Cyprus
  }

  # Determine if entity or individual
  if (is_entity(vendor$company_reg)) {
    add_entity_seller(identity_node, vendor, country_code, log)
  } else {
    add_individual_seller(identity_node, vendor, country_code, receiving_country, placeholder_dob, log)
  }

  # Relevant Activities (income, fees, etc.)
  add_relevant_activities(seller_node, vendor)

  # DocSpec
  doc_spec <- xml_add_child(seller_node, "dpi:DocSpec")
  xml_add_child(doc_spec, "stf:DocTypeIndic", "OECD1")
  xml_add_child(doc_spec, "stf:DocRefId", generate_doc_ref_id(sending_country, year))
}

# ============================================================================
# MAIN XML GENERATION FUNCTION
# ============================================================================

#' Create the complete DPI XML document
#' @param vendors Data frame of vendor data (post clean_vendor_data())
#' @param platform_operator List with platform operator details
#' @param reporting_config List with reporting configuration
#' @param placeholder_dob date string used when a seller has no DOB on file (default matches
#'   the value historically hardcoded in xml.R)
#' @param log optional fallback log (see new_fallback_log())
#' @param progress_callback optional function(i, n) called after each vendor is processed,
#'   for callers (e.g. the Shiny app) that want to show progress on a long run. No-op if NULL.
#' @return xml_document object
create_dpi_xml <- function(vendors, platform_operator, reporting_config, placeholder_dob = "1900-01-01",
                            log = NULL, progress_callback = NULL) {

  year <- reporting_config$reporting_year

  # Namespace URIs
  ns_dpi <- "urn:oecd:ties:dpi:v1"
  ns_stf <- "urn:oecd:ties:dpistf:v1"
  ns_xsi <- "http://www.w3.org/2001/XMLSchema-instance"

  # Create root element with namespaces
  doc <- xml_new_root(
    "dpi:DPI_OECD",
    "xmlns:dpi" = ns_dpi,
    "xmlns:stf" = ns_stf,
    "xmlns:xsi" = ns_xsi,
    version = "1.0",
    "xsi:schemaLocation" = "urn:oecd:ties:dpi:v1 DPIXML_v1.0.xsd"
  )

  root <- xml_root(doc)

  # ---- MessageSpec Section ----
  message_spec <- xml_add_child(root, "dpi:MessageSpec")
  xml_add_child(message_spec, "dpi:TransmittingCountry", reporting_config$transmitting_country)
  xml_add_child(message_spec, "dpi:ReceivingCountry", reporting_config$receiving_country)
  xml_add_child(message_spec, "dpi:MessageType", "DPI")
  xml_add_child(message_spec, "dpi:MessageRefId",
                generate_message_ref_id(reporting_config$transmitting_country,
                                        reporting_config$receiving_country,
                                        year))
  xml_add_child(message_spec, "dpi:MessageTypeIndic", reporting_config$message_type_indic)
  xml_add_child(message_spec, "dpi:ReportingPeriod", reporting_config$reporting_period)
  xml_add_child(message_spec, "dpi:Timestamp", format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))

  # ---- DPIBody Section ----
  dpi_body <- xml_add_child(root, "dpi:DPIBody")

  # Platform Operator
  add_platform_operator(dpi_body, platform_operator, year, ns_dpi, ns_stf)

  # Reportable Sellers (one per vendor)
  n_vendors <- nrow(vendors)
  for (i in seq_len(n_vendors)) {
    vendor <- vendors[i, ]
    add_reportable_seller(dpi_body, vendor, year,
                           reporting_config$transmitting_country,
                           reporting_config$receiving_country,
                           placeholder_dob,
                           log)
    if (!is.null(progress_callback)) progress_callback(i, n_vendors)
  }

  return(doc)
}
