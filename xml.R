# ============================================================================
# OECD DPI XML Generator for Cyprus Tax Department
# ============================================================================
# This script generates the Digital Platform Information (DPI) XML file
# for reporting vendor/seller data to the Cyprus Tax Department
#
# ============================================================================

library(readxl)
library(dplyr)
library(stringr)
library(xml2)
library(lubridate)
library(uuid)


path_main <- "c:/Users/pcuser/OneDrive/IMPROVAST/ACS/tax_xml"
path_data <- file.path(path_main, 'data')
path_export <- file.path(path_main, 'exports')

vendors <- read_excel(file.path(path_data, "DAC FINAL 2025.xlsx"), na = c('', 'NA', 'N/A'))

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

vendors <- vendors |>
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



# NEED

# keep only vendors with reportable annual income
vendors <- vendors |>
  mutate(annual_income = income_q1 + income_q2 + income_q3 + income_q4) |>
  filter(annual_income > 0)


# ============================================================================
# CONFIGURATION - Platform Operator Details (SAMPLE - Replace with actual)
# ============================================================================

platform_operator <- list(
  tin = "CY12345678A",
  vat = "CY12345678X",
  name = "ACS COurier Services LTD",
  business_name = "ACS Courier Services",
  street = "Varkizas 14",
  #building = "123",
  #floor = "0",
  postcode = "2033",
  city = "Nicosia",
  district = "Nicosia",
  country_code = "CY"
  #country = "Cyprus"
)

# Reporting configuration
reporting_config <- list(
  transmitting_country = "CY",
  receiving_country = "CY",
  reporting_period = "2025-12-31",
  reporting_year = "2025",  # PLACEHOLDER - set to the year being reported; used in DocRefId/MessageRefId
  message_type_indic = "DPI401"  # DPI401 = New data, DPI402 = Corrected data
)

placeholder_dob <- "1900-01-01"  # Placeholder DOB for individuals without DOB

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

#' Generate a UUID v4
# generate_uuid <- function() {
#   paste0(
#     paste0(sample(c(0:9, letters[1:6]), 8, replace = TRUE), collapse = ""), "-",
#     paste0(sample(c(0:9, letters[1:6]), 4, replace = TRUE), collapse = ""), "-",
#     "4", paste0(sample(c(0:9, letters[1:6]), 3, replace = TRUE), collapse = ""), "-",
#     sample(c("8", "9", "a", "b"), 1), paste0(sample(c(0:9, letters[1:6]), 3, replace = TRUE), collapse = ""), "-",
#     paste0(sample(c(0:9, letters[1:6]), 12, replace = TRUE), collapse = "")
#   )
# }

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

#' #' Extract country code from IBAN
#' #  NOT GOOD FOR ALL CASES!!!!!!! example revolut and lithuanai
#' get_country_from_iban <- function(iban) {
#'   substr(gsub("\\s+", "", iban), 1, 2)
#' }

#' Map country name to ISO 2-letter code
map_country_name_to_code <- function(country_name) {

  original_name <- country_name
  country_name <- countrycode::countryname(country_name)

  code <- countrycode::countrycode(country_name, 'country.name', destination = 'iso2c')

  return(code)

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
  #xml_add_child(address_fix, "dpi:BuildingIdentifier", po$building)
  # if (!is.null(po$floor) && !is.na(po$floor)) {
  #   xml_add_child(address_fix, "dpi:FloorIdentifier", po$floor)
  # }
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
add_address <- function(parent, address_text, country_code) {
  address_node <- xml_add_child(parent, "dpi:Address")
  xml_set_attr(address_node, "legalAddressType", "OECD301")

  xml_add_child(address_node, "dpi:CountryCode", country_code)

  cleaned <- clean_address(address_text)
  if (is.na(cleaned)) {
    xml_add_child(address_node, "dpi:AddressFree", "Address unknown")
  } else {
    xml_add_child(address_node, "dpi:AddressFree", cleaned)
  }
}

#' Add Entity Seller (Company) to XML
add_entity_seller <- function(parent, vendor, country_code) {
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
  add_address(ent_seller_id, vendor$address, country_code)

  # Financial Identifier (IBAN)
  add_financial_identifier(standard, vendor$iban)
}

#' Add Individual Seller (Person) to XML
add_individual_seller <- function(parent, vendor, country_code) {
  ind_seller <- xml_add_child(parent, "dpi:IndividualSeller")
  standard <- xml_add_child(ind_seller, "dpi:Standard")
  ind_seller_id <- xml_add_child(standard, "dpi:IndSellerID")

  xml_add_child(ind_seller_id, "dpi:ResCountryCode", country_code)

  # TIN - prefer TAX NUMBER, fall back to the ID column, else unknown
  if (!is.na(vendor$tax_number) && vendor$tax_number != "" && vendor$tax_number != "N/A") {
    tin_node <- xml_add_child(ind_seller_id, "dpi:TIN", vendor$tax_number)
    xml_set_attr(tin_node, "issuedBy", country_code)
  } else if (!is.na(vendor$id_number) && vendor$id_number != "") {
    tin_node <- xml_add_child(ind_seller_id, "dpi:TIN", vendor$id_number)
    xml_set_attr(tin_node, "issuedBy", country_code)
  } else {
    tin_node <- xml_add_child(ind_seller_id, "dpi:TIN")
    xml_set_attr(tin_node, "unknown", "true")
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
  add_address(ind_seller_id, vendor$address, country_code)

  # BirthInfo (required for individuals)
  birth_info <- xml_add_child(ind_seller_id, "dpi:BirthInfo")

  # BirthDate - use provided DOB or unknown
  if (!is.na(vendor$dob) && vendor$dob != "N/A" && vendor$dob != "") {

    xml_add_child(birth_info, "dpi:BirthDate", vendor$dob)

  } else {

    xml_add_child(birth_info, "dpi:BirthDate", placeholder_dob)

    # If no DOB, we need at least a BirthDate element with unknown attribute
    # or provide a placeholder date - check with tax authority which they prefer
    # birth_date_node <- xml_add_child(birth_info, "dpi:BirthDate")
    # xml_set_attr(birth_date_node, "unknown", "true")

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
add_reportable_seller <- function(parent, vendor, year) {

  seller_node <- xml_add_child(parent, "dpi:ReportableSeller")

  # Identity section
  identity_node <- xml_add_child(seller_node, "dpi:Identity")

  country_code <- map_country_name_to_code(vendor$country_tax)

  if (is.na(country_code)) {
    message("Could not map country '", vendor$country_tax, " of vendor ", vendor$producer, "' to an ISO code - defaulting to CY")
    country_code <- "CY"  # Default to Cyprus
  }

  # Determine if entity or individual
  if (is_entity(vendor$company_reg)) {
    add_entity_seller(identity_node, vendor, country_code)
  } else {
    add_individual_seller(identity_node, vendor, country_code)
  }

  # Relevant Activities (income, fees, etc.)
  add_relevant_activities(seller_node, vendor)

  # DocSpec
  doc_spec <- xml_add_child(seller_node, "dpi:DocSpec")
  xml_add_child(doc_spec, "stf:DocTypeIndic", "OECD1")
  xml_add_child(doc_spec, "stf:DocRefId", generate_doc_ref_id(country_code, year))
}

# ============================================================================
# MAIN XML GENERATION FUNCTION
# ============================================================================

#' Create the complete DPI XML document
#' @param vendors Data frame of vendor data
#' @param platform_operator List with platform operator details
#' @param reporting_config List with reporting configuration
#' @return xml_document object
create_dpi_xml <- function(vendors, platform_operator, reporting_config) {

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
  for (i in seq_len(nrow(vendors))) {
    vendor <- vendors[i, ]
    add_reportable_seller(dpi_body, vendor, year)
  }

  return(doc)
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

cat("======================================================================\n")
cat("OECD DPI XML Generator for Cyprus Tax Department\n")
cat("======================================================================\n\n")

cat("Configuration:\n")
cat("  Platform Operator:", platform_operator$name, "\n")
cat("  Reporting Period:", reporting_config$reporting_period, "\n")
cat("  Message Type:", reporting_config$message_type_indic, "\n\n")

cat("Processing", nrow(vendors), "vendors...\n")

# Count entity vs individual sellers
n_entities <- sum(sapply(vendors$company_reg, is_entity))
n_individuals <- nrow(vendors) - n_entities

cat("  - Entity sellers (companies):", n_entities, "\n")
cat("  - Individual sellers:", n_individuals, "\n\n")

# Generate XML
xml_doc <- create_dpi_xml(vendors, platform_operator, reporting_config)


# Output file

file_name <- paste0( "dpi_report_", format(Sys.Date(), "%Y%m%d"), ".xml")
output_file <- file.path( path_export, file_name )
write_xml(xml_doc, output_file)

cat("Output file:", output_file, "\n")
cat("File size:", file.size(output_file), "bytes\n\n")

cat("======================================================================\n")
cat("XML generation complete!\n")
cat("======================================================================\n")

# Optional: Print preview of first 100 lines
cat("\nPreview (first 100 lines):\n")
cat("----------------------------------------------------------------------\n")
xml_text <- readLines(output_file, n = 100, warn = FALSE)
cat(xml_text, sep = "\n")


# VALIDATE

doc <- read_xml(output_file)

xsd <- read_xml(file.path(path_data, "xsd_validation", "DPIXML_v1.0.xsd"))

validation_result <- xml_validate(doc, xsd)

if (isTRUE(validation_result)) {
  cat("\nXSD validation: PASSED\n")
} else {
  cat("\nXSD validation: FAILED\n")
  print(attr(validation_result, "errors"))
}


# MessageTypeIndic tells the tax authority what type of submission this is:
# CodeMeaningDPI401New data - First/initial submission for the reporting periodDPI402Corrected data - Amendments/corrections to previously submitted dataDPI403No data to report (nil return)
# When to use each:
#
# DPI401: Use this for your first submission for the year (e.g., reporting 2024 vendor data for the first time)
# DPI402: Use this if you already submitted and need to correct errors or add missing vendors. When correcting, you also need to update the DocTypeIndic in DocSpec:
#
# OECD1 = New record
# OECD2 = Corrected record
# OECD3 = Delete previously sent record
#
#
# DPI403: Use if you're a platform operator but had no reportable sellers that year
#
# For your initial submission, DPI401 is correct. If you later discover errors (wrong IBAN, missing vendor, incorrect amounts), you'd resubmit with DPI402 and mark the specific records as OECD2 (corrected) or OECD3 (deleted).
