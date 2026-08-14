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

# All parsing/classification/XML-building logic lives in dpi_functions.R,
# shared with the Shiny app (app.R) so the two entry points never drift on
# the business rules.
source(file.path(path_main, "dpi_functions.R"))

vendors <- read_excel(file.path(path_data, "DAC FINAL 2025.xlsx"), na = c('', 'NA', 'N/A'))
vendors <- clean_vendor_data(vendors)

# ============================================================================
# CONFIGURATION - Platform Operator Details (SAMPLE - Replace with actual)
# ============================================================================

platform_operator <- list(
  tin = "12307173V",
  vat = "10307173T",
  name = "Tickethour (Cyprus) Ltd",
  business_name = "Tickethour",
  street = "Giannou Kranidioti 10, Office 602",
  postcode = "1065",
  #name = "ACS Courier Services LTD",
  #business_name = "ACS Courier Services",
  #street = "Varkizas 14",

  #building = "NICE DAY HOUSE",
  #floor = "6",
  #postcode = "2033",
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

seller_is_entity <- sapply(vendors$company_reg, is_entity)
# Count entity vs individual sellers
n_entities <- sum(seller_is_entity)
n_individuals <- nrow(vendors) - n_entities

cat("  - Entity sellers (companies):", n_entities, "\n")
cat("  - Individual sellers:", n_individuals, "\n\n")

# Export producer classification (Entity vs Individual) to CSV
classification <- vendors |>
  mutate(
    seller_type = if_else(sapply(vendors$company_reg, is_entity), "Entity", "Individual")
  ) |>
  select(producer, seller_type, company_reg, tax_number, dob)

classification_file <- file.path(path_export, paste0("seller_classification_", format(Sys.Date(), "%Y%m%d"), ".csv"))
write.csv(classification, classification_file, row.names = FALSE, fileEncoding = "UTF-8")
cat("Classification CSV:", classification_file, "\n\n")

# Generate XML
xml_doc <- create_dpi_xml(vendors, platform_operator, reporting_config, placeholder_dob = placeholder_dob)


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
