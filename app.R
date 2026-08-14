# ============================================================================
# OECD DPI (DAC7) XML Generator - Shiny app
# ============================================================================
# Upload the producers Excel file, review/adjust the platform operator and
# reporting configuration (pre-filled with the same defaults as xml.R), see a
# report of every fallback rule that was applied, confirm the file validates
# against the OECD DPI schema, and download the XML.
#
# All business logic (parsing, entity classification, TIN/DOB/address
# fallbacks, DocRefId/BirthPlace/ResCountryCode rules) lives in
# dpi_functions.R, shared with the CLI script (xml.R), so the two entry
# points can never drift on the rules.
# ============================================================================

library(shiny)
library(DT)
library(xml2)
library(readxl)
library(dplyr)

source("dpi_functions.R")

XSD_PATH <- file.path("data", "xsd_validation", "DPIXML_v1.0.xsd")
COUNTRY_XSD_PATH <- file.path("data", "xsd_validation", "isodpitypes_v1.0.xsd")

# Parsed once at app startup (static data, shared across all sessions)
country_lookup <- get_dpi_country_codes(COUNTRY_XSD_PATH)
country_choices <- setNames(country_lookup$code, paste0(country_lookup$name, " (", country_lookup$code, ")"))

current_year <- as.integer(format(Sys.Date(), "%Y"))

# Defaults - identical to the literals hardcoded in xml.R
DEFAULTS <- list(
  tin = "12307173V",
  vat = "10307173T",
  name = "Tickethour (Cyprus) Ltd",
  business_name = "Tickethour",
  street = "Giannou Kranidioti 10, Office 602",
  postcode = "1065",
  city = "Nicosia",
  district = "Nicosia",
  po_country = "CY",
  transmitting_country = "CY",
  receiving_country = "CY",
  year = 2025L,
  message_type_indic = "DPI401",
  placeholder_dob = as.Date("1900-01-01")
)

# ============================================================================
# UI
# ============================================================================

ui <- fluidPage(
  titlePanel("OECD DPI (DAC7) XML Generator"),

  ## ---- Section 1: Upload ----
  wellPanel(
    h3("1. Upload producers file"),
    fileInput("file", "Excel file (.xlsx)", accept = c(".xlsx")),
    uiOutput("upload_status")
  ),

  ## ---- Section 2: Configure ----
  conditionalPanel(
    condition = "output.show_config",
    wellPanel(
      h3("2. Reporting configuration"),
      fluidRow(
        column(6,
          h4("Platform operator"),
          textInput("tin", "TIN", DEFAULTS$tin),
          textInput("vat", "VAT", DEFAULTS$vat),
          textInput("name", "Legal name", DEFAULTS$name),
          textInput("business_name", "Platform business name", DEFAULTS$business_name),
          textInput("street", "Street", DEFAULTS$street),
          textInput("postcode", "Postcode", DEFAULTS$postcode),
          textInput("city", "City", DEFAULTS$city),
          textInput("district", "District", DEFAULTS$district),
          selectInput("po_country", "Country", choices = country_choices, selected = DEFAULTS$po_country)
        ),
        column(6,
          h4("Reporting period & submission"),
          numericInput("year", "Reporting year", value = DEFAULTS$year,
                       min = 2020, max = current_year + 1, step = 1),
          helpText("Reporting period is always the full calendar year (Jan 1 - Dec 31) of the year above."),
          selectInput("transmitting_country", "Transmitting country", choices = country_choices,
                      selected = DEFAULTS$transmitting_country),
          selectInput("receiving_country", "Receiving country", choices = country_choices,
                      selected = DEFAULTS$receiving_country),
          selectInput("message_type_indic", "Message type",
                      choices = c("DPI401 - New data" = "DPI401",
                                  "DPI402 - Corrected data" = "DPI402",
                                  "DPI403 - Nil return" = "DPI403"),
                      selected = DEFAULTS$message_type_indic),
          dateInput("placeholder_dob", "Placeholder date of birth (used when a seller has no DOB on file)",
                    value = DEFAULTS$placeholder_dob)
        )
      ),
      uiOutput("config_errors_ui"),
      actionButton("generate", "Generate DPI XML", class = "btn-primary")
    )
  ),

  ## ---- Section 3: Results ----
  conditionalPanel(
    condition = "output.show_results",
    wellPanel(
      h3("3. Results"),
      uiOutput("validation_banner"),
      uiOutput("summary_counts"),
      h4("Missing data / fallback report"),
      p("Every row below records a place where the source data was missing or ambiguous, and how the tool filled the gap."),
      DTOutput("fallback_table"),
      h4("Seller classification"),
      DTOutput("classification_table"),
      br(),
      downloadButton("download_xml", "Download XML"),
      downloadButton("download_classification", "Download classification CSV"),
      downloadButton("download_fallback", "Download fallback report CSV")
    )
  )
)

# ============================================================================
# SERVER
# ============================================================================

server <- function(input, output, session) {

  ## ---- Upload + structural validation ----

  raw_upload <- reactive({
    req(input$file)
    tryCatch(
      read_excel(input$file$datapath, na = c('', 'NA', 'N/A')),
      error = function(e) structure(list(error = conditionMessage(e)), class = "upload_read_error")
    )
  })

  col_check <- reactive({
    req(input$file)
    df <- raw_upload()
    if (inherits(df, "upload_read_error")) {
      return(list(ok = FALSE, missing_columns = character(), n_rows = 0, read_error = df$error))
    }
    c(validate_source_columns(df), list(read_error = NULL))
  })

  output$upload_status <- renderUI({
    req(input$file)
    cc <- col_check()
    if (!is.null(cc$read_error)) {
      div(class = "alert alert-danger",
          strong("Could not read this file as an Excel spreadsheet: "), cc$read_error)
    } else if (cc$ok) {
      div(class = "alert alert-success",
          sprintf("%d rows loaded. All required columns are present.", cc$n_rows))
    } else {
      tagList(
        div(class = "alert alert-danger",
            strong("This file is missing required columns and cannot be processed:")),
        tags$ul(lapply(cc$missing_columns, tags$li))
      )
    }
  })

  output$show_config <- reactive({
    req(input$file)
    isTRUE(col_check()$ok)
  })
  outputOptions(output, "show_config", suspendWhenHidden = FALSE)

  vendors_clean <- reactive({
    req(col_check()$ok)
    clean_vendor_data(raw_upload())
  })

  ## ---- Configuration reactives + validation ----

  platform_operator_cfg <- reactive({
    list(
      tin = input$tin, vat = input$vat, name = input$name,
      business_name = input$business_name, street = input$street,
      postcode = input$postcode, city = input$city, district = input$district,
      country_code = input$po_country
    )
  })

  reporting_cfg <- reactive({
    req(input$year)
    list(
      transmitting_country = input$transmitting_country,
      receiving_country = input$receiving_country,
      reporting_period = paste0(input$year, "-12-31"),
      reporting_year = as.character(input$year),
      message_type_indic = input$message_type_indic
    )
  })

  # Hard-blocking errors - generation is disabled until these are fixed
  config_errors <- reactive({
    errs <- character()
    required_text <- list(
      "Legal name" = input$name, "Platform business name" = input$business_name,
      "Street" = input$street, "Postcode" = input$postcode,
      "City" = input$city, "District" = input$district,
      "TIN" = input$tin, "VAT" = input$vat
    )
    for (label in names(required_text)) {
      if (is.null(required_text[[label]]) || trimws(required_text[[label]]) == "") {
        errs <- c(errs, paste0(label, " is required."))
      }
    }
    if (is.null(input$year) || is.na(input$year) || input$year < 2020 || input$year > current_year + 1) {
      errs <- c(errs, paste0("Reporting year must be between 2020 and ", current_year + 1, "."))
    }
    if (is.null(input$placeholder_dob) || is.na(input$placeholder_dob) || input$placeholder_dob > Sys.Date()) {
      errs <- c(errs, "Placeholder date of birth must be a valid date in the past.")
    }
    errs
  })

  # Soft warnings - shown, but do not block generation
  config_warnings <- reactive({
    warns <- character()
    cy_tin_regex <- "^[0-9]{8}[A-Za-z]$"
    if (!is.null(input$tin) && trimws(input$tin) != "" && !grepl(cy_tin_regex, input$tin)) {
      warns <- c(warns, "TIN does not match the usual Cyprus format (8 digits + 1 letter) - double-check it.")
    }
    if (!is.null(input$vat) && trimws(input$vat) != "" && !grepl(cy_tin_regex, input$vat)) {
      warns <- c(warns, "VAT does not match the usual Cyprus format (8 digits + 1 letter) - double-check it.")
    }
    warns
  })

  output$config_errors_ui <- renderUI({
    errs <- config_errors()
    warns <- config_warnings()
    tagList(
      if (length(errs) > 0) tagList(
        div(class = "alert alert-danger", strong("Fix these before generating:")),
        tags$ul(lapply(errs, tags$li))
      ),
      if (length(warns) > 0) tagList(
        div(class = "alert alert-warning", strong("Please double-check:")),
        tags$ul(lapply(warns, tags$li))
      )
    )
  })

  ## ---- Generate ----

  generate_result <- eventReactive(input$generate, {
    req(vendors_clean())
    validate(need(length(config_errors()) == 0,
                  "Please fix the configuration errors above before generating."))

    log <- new_fallback_log()

    xml_doc <- tryCatch({
      create_dpi_xml(vendors_clean(), platform_operator_cfg(), reporting_cfg(),
                      placeholder_dob = as.character(input$placeholder_dob), log = log)
    }, error = function(e) {
      validate(paste("Could not generate the XML:", conditionMessage(e)))
    })

    tmp <- tempfile(fileext = ".xml")
    write_xml(xml_doc, tmp)

    xsd <- read_xml(XSD_PATH)
    validation_result <- xml_validate(read_xml(tmp), xsd)

    vendors_df <- vendors_clean()
    seller_is_entity <- sapply(vendors_df$company_reg, is_entity)
    classification_df <- vendors_df |>
      mutate(seller_type = if_else(seller_is_entity, "Entity", "Individual")) |>
      select(producer, seller_type, company_reg, tax_number, dob)

    list(
      xml_doc = xml_doc,
      validation = validation_result,
      fallback_df = fallback_log_to_df(log),
      classification_df = classification_df,
      n_entities = sum(seller_is_entity),
      n_individuals = nrow(vendors_df) - sum(seller_is_entity),
      n_total = nrow(vendors_df)
    )
  })

  output$show_results <- reactive({
    !is.null(tryCatch(generate_result(), error = function(e) NULL))
  })
  outputOptions(output, "show_results", suspendWhenHidden = FALSE)

  output$validation_banner <- renderUI({
    res <- generate_result()
    if (isTRUE(res$validation)) {
      div(class = "alert alert-success",
          strong("XSD validation: PASSED"), " - the file is schema-valid against the DPI XSD.")
    } else {
      tagList(
        div(class = "alert alert-danger", strong("XSD validation: FAILED")),
        tags$pre(paste(capture.output(print(attr(res$validation, "errors"))), collapse = "\n"))
      )
    }
  })

  output$summary_counts <- renderUI({
    res <- generate_result()
    p(sprintf("Processed %d vendors: %d entity sellers (companies), %d individual sellers.",
              res$n_total, res$n_entities, res$n_individuals))
  })

  output$fallback_table <- renderDT({
    datatable(generate_result()$fallback_df, options = list(pageLength = 10), rownames = FALSE)
  })

  output$classification_table <- renderDT({
    datatable(generate_result()$classification_df, options = list(pageLength = 10), rownames = FALSE)
  })

  ## ---- Downloads ----

  output$download_xml <- downloadHandler(
    filename = function() paste0("dpi_report_", format(Sys.Date(), "%Y%m%d"), ".xml"),
    content = function(file) write_xml(generate_result()$xml_doc, file)
  )

  output$download_classification <- downloadHandler(
    filename = function() paste0("seller_classification_", format(Sys.Date(), "%Y%m%d"), ".csv"),
    content = function(file) write.csv(generate_result()$classification_df, file, row.names = FALSE, fileEncoding = "UTF-8")
  )

  output$download_fallback <- downloadHandler(
    filename = function() paste0("fallback_report_", format(Sys.Date(), "%Y%m%d"), ".csv"),
    content = function(file) write.csv(generate_result()$fallback_df, file, row.names = FALSE, fileEncoding = "UTF-8")
  )
}

shinyApp(ui, server)
