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

current_year <- as.integer(format(Sys.Date(), "%Y"))

# Country is not configurable: the platform operator is Cypriot and the file
# is always transmitted by / to the Cyprus Tax Department.
FIXED_COUNTRY <- "CY"

# Defaults - identical to the literals hardcoded in xml.R.
# District is not asked for separately - it always mirrors City.
DEFAULTS <- list(
  tin = "12307173V",
  vat = "10307173T",
  name = "Tickethour (Cyprus) Ltd",
  business_name = "Tickethour",
  street = "Giannou Kranidioti 10, Office 602",
  postcode = "1065",
  city = "Nicosia",
  year = 2025L,
  message_type_indic = "DPI401",
  placeholder_dob = as.Date("1900-01-01")
)

# Label with a small muted note on the same line (keeps inputs aligned).
label_with_note <- function(label, note) {
  tagList(label, tags$span(class = "label-note", note))
}

# ============================================================================
# UI
# ============================================================================

app_css <- "
  /* ---- Compact sidebar form ---- */
  .sidebar-compact { padding: 12px 14px; }
  .sidebar-compact h4 { margin: 0 0 8px 0; font-size: 16px; font-weight: 600; }
  .sidebar-compact h5 { margin: 10px 0 6px 0; font-size: 13px; font-weight: 600;
                        text-transform: uppercase; letter-spacing: .03em; color: #555;
                        border-bottom: 1px solid #ddd; padding-bottom: 3px; }
  .sidebar-compact .form-group { margin-bottom: 6px; }
  .sidebar-compact label { font-size: 12px; margin-bottom: 2px; white-space: nowrap; }
  .sidebar-compact .form-control { height: 30px; padding: 4px 8px; font-size: 13px; }
  .sidebar-compact .form-control[readonly] { background-color: #eee; cursor: not-allowed; }
  .sidebar-compact .row { margin-left: -5px; margin-right: -5px; }
  .sidebar-compact .row > [class*='col-'] { padding-left: 5px; padding-right: 5px; }
  .sidebar-compact .shiny-input-container { width: 100%; }
  .sidebar-compact .input-group .btn { padding: 4px 10px; font-size: 13px; }
  .sidebar-compact .progress { margin-bottom: 4px; }
  #file_progress { height: 6px; margin-bottom: 2px; }
  .sidebar-compact .alert { padding: 6px 10px; margin-bottom: 6px; font-size: 12px; }
  .sidebar-compact ul { font-size: 12px; padding-left: 18px; margin-bottom: 6px; }
  .label-note { font-weight: normal; color: #888; margin-left: 4px; }
  #generate { width: 100%; margin-top: 6px; font-weight: 600; }

  /* ---- 'Reading file' spinner shown instantly when a file is chosen ---- */
  .spinner { display: inline-block; width: 14px; height: 14px; margin-right: 6px;
             vertical-align: -2px; border: 2px solid currentColor;
             border-right-color: transparent; border-radius: 50%;
             animation: spin .7s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ---- Download bar at the top of the Results ---- */
  .download-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 10px;
                  padding: 12px 16px; margin-bottom: 15px;
                  background: #eef6ee; border: 1px solid #5cb85c;
                  border-left: 6px solid #5cb85c; border-radius: 4px; }
  .download-bar-label { font-size: 16px; font-weight: 600; margin-right: 6px; color: #2d672d; }
  .download-bar .btn { font-weight: 600; }

  /* ---- Progress notification: big, top-centre, hard to miss ---- */
  #shiny-notification-panel {
    top: 15px; bottom: auto; left: 50%; right: auto;
    transform: translateX(-50%);
    width: 460px; max-width: calc(100% - 32px);
  }
  .shiny-notification {
    opacity: 1; font-size: 15px; padding: 14px 18px;
    border: 1px solid #337ab7; border-left: 6px solid #337ab7;
    box-shadow: 0 6px 24px rgba(0,0,0,.25);
  }
  .shiny-progress-notification .progress { height: 12px; margin-top: 8px; }
  .shiny-progress-notification .progress-message { font-weight: 600; }
"

# While a generation is running, lock the button and say so on it; Shiny goes
# idle again once the server has finished (success or validation error).
app_js <- "
  // Instant feedback while the browser sends the file and R reads it; the
  // server's upload_status message replaces this as soon as it is ready.
  $(document).on('change', '#file', function() {
    if (this.files && this.files.length) {
      $('#upload_status').html('<div class=\"alert alert-info\"><span class=\"spinner\"></span>' +
        'Reading file <b>' + $('<span>').text(this.files[0].name).html() + '</b>\\u2026</div>');
    }
  });

  $(document).on('click', '#generate', function() {
    var btn = $(this);
    if (btn.prop('disabled')) return;
    btn.data('label', btn.html());
    setTimeout(function() {
      btn.prop('disabled', true).html('Working on it\\u2026');
    }, 0);
  });
  $(document).on('shiny:idle', function() {
    var btn = $('#generate');
    if (btn.data('label')) btn.prop('disabled', false).html(btn.data('label'));
  });
"

ui <- fluidPage(
  tags$head(tags$style(HTML(app_css)), tags$script(HTML(app_js))),
  titlePanel("OECD DPI (DAC7) XML Generator"),

  sidebarLayout(
    ## ---- Sidebar: upload + configuration ----
    sidebarPanel(
      width = 3, class = "sidebar-compact",

      h4("Upload producers file"),
      fileInput("file", NULL, accept = c(".xlsx"), placeholder = "Excel file (.xlsx)"),
      uiOutput("upload_status"),

      conditionalPanel(
        condition = "output.show_config",
        h4("Reporting configuration", style = "margin-top: 12px;"),

        h5("Platform operator"),
        fluidRow(
          column(6, textInput("tin", "TIN", DEFAULTS$tin)),
          column(6, textInput("vat", "VAT", DEFAULTS$vat))
        ),
        textInput("name", "Legal name", DEFAULTS$name),
        textInput("business_name", "Platform business name", DEFAULTS$business_name),
        textInput("street", "Street", DEFAULTS$street),
        fluidRow(
          column(4, textInput("postcode", "Postcode", DEFAULTS$postcode)),
          column(4, textInput("city", label_with_note("City", "(= district)"), DEFAULTS$city)),
          column(4, div(class = "form-group shiny-input-container",
            tags$label("Country"),
            tags$input(type = "text", class = "form-control", value = "Cyprus",
                       readonly = NA, title = "Always Cyprus - not editable")
          ))
        ),

        h5("Reporting period & submission"),
        numericInput("year", label_with_note("Reporting year", "(full calendar year, 1 Jan - 31 Dec)"),
                     value = DEFAULTS$year, min = 2020, max = current_year + 1, step = 1),
        fluidRow(
          column(6, textInput("message_type_indic", "Message type", value = DEFAULTS$message_type_indic)),
          column(6, dateInput("placeholder_dob", label_with_note("Placeholder DOB", "(if missing)"),
                              value = DEFAULTS$placeholder_dob, format = "dd/mm/yyyy"))
        ),

        uiOutput("config_errors_ui"),
        actionButton("generate", "Generate DPI XML", class = "btn-primary")
      )
    ),

    ## ---- Main panel: results ----
    mainPanel(
      width = 9,
      conditionalPanel(
        condition = "!output.show_results",
        div(class = "text-muted", style = "padding: 40px 0; text-align: center; font-size: 16px;",
            "Upload the producers file and press ", strong("Generate DPI XML"),
            " - the results will appear here.")
      ),
      conditionalPanel(
        condition = "output.show_results",
        #h3("Results", style = "margin-top: 0;"),
        div(class = "download-bar",
          span(class = "download-bar-label", icon("download"), " Download"),
          downloadButton("download_xml", "DPI XML file", class = "btn-success btn-lg"),
          downloadButton("download_classification", "Classification CSV", class = "btn-primary btn-lg"),
          downloadButton("download_fallback", "Fallback report CSV", class = "btn-primary btn-lg")
        ),
        uiOutput("validation_banner"),
        uiOutput("summary_counts"),
        uiOutput("excluded_banner"),
        fluidRow(
          column(6,
            div(class = "panel panel-warning",
              div(class = "panel-heading", h2("Missing data / fallback report", style = "margin: 0; font-size: 18px;")),
              div(class = "panel-body",
                p("Every row records a place where the source data was missing or ambiguous, and how the tool filled the gap."),
                DTOutput("fallback_table")
              )
            )
          ),
          column(6,
            div(class = "panel panel-info",
              div(class = "panel-heading", h2("Seller classification", style = "margin: 0; font-size: 18px;")),
              div(class = "panel-body",
                p("Every reported producer and whether it was classified as a company (Entity) or a person (Individual)."),
                DTOutput("classification_table")
              )
            )
          )
        )
      )
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
      postcode = input$postcode, city = input$city, district = input$city,
      country_code = FIXED_COUNTRY
    )
  })

  reporting_cfg <- reactive({
    req(input$year)
    list(
      transmitting_country = FIXED_COUNTRY,
      receiving_country = FIXED_COUNTRY,
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
      "City" = input$city,
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
    vendors_df <- vendors_clean()
    req(vendors_df)
    validate(need(length(config_errors()) == 0,
                  "Please fix the configuration errors above before generating."))

    log <- new_fallback_log()

    withProgress(message = "Generating DPI XML...", value = 0, max = nrow(vendors_df), {

      xml_doc <- tryCatch({
        create_dpi_xml(vendors_df, platform_operator_cfg(), reporting_cfg(),
                        placeholder_dob = as.character(input$placeholder_dob), log = log,
                        progress_callback = function(i, n) {
                          incProgress(1, detail = sprintf("seller %d of %d", i, n))
                        })
      }, error = function(e) {
        validate(paste("Could not generate the XML:", conditionMessage(e)))
      })

      setProgress(detail = "Validating against the OECD schema...")
      tmp <- tempfile(fileext = ".xml")
      write_xml(xml_doc, tmp)

      xsd <- read_xml(XSD_PATH)
      validation_result <- xml_validate(read_xml(tmp), xsd)

      seller_is_entity <- sapply(vendors_df$company_reg, is_entity)
      classification_df <- vendors_df |>
        mutate(seller_type = if_else(seller_is_entity, "Entity", "Individual")) |>
        select(producer, seller_type, company_reg, tax_number, dob)

      excluded_df <- get_excluded_vendors(raw_upload()) |>
        select(producer, country_tax)

      list(
        xml_doc = xml_doc,
        validation = validation_result,
        fallback_df = fallback_log_to_df(log),
        classification_df = classification_df,
        excluded_df = excluded_df,
        n_entities = sum(seller_is_entity),
        n_individuals = nrow(vendors_df) - sum(seller_is_entity),
        n_total = nrow(vendors_df)
      )
    })
  })

  output$show_results <- reactive({
    !is.null(tryCatch(generate_result(), error = function(e) NULL))
  })
  outputOptions(output, "show_results", suspendWhenHidden = FALSE)

  # Pop up a confirmation the moment generation finishes, so the user notices
  # even though the Results section renders further down the page.
  # The modal is deferred until this flush's outputs (banners + tables) have
  # been sent, so the tables are already on the page when the popup appears.
  observeEvent(input$generate, {
    res <- tryCatch(generate_result(), error = function(e) NULL)
    req(res)
    session$onFlushed(once = TRUE, function() showModal(modalDialog(
      title = "Conversion complete",
      if (isTRUE(res$validation)) {
        tagList(
          div(class = "alert alert-success", strong("XSD validation: PASSED")),
          p(sprintf("Processed %d vendors: %d entity sellers, %d individual sellers.",
                    res$n_total, res$n_entities, res$n_individuals))
        )
      } else {
        div(class = "alert alert-danger",
            strong("XSD validation: FAILED"), " - see the Results section below for details.")
      },
      easyClose = TRUE,
      footer = modalButton("OK")
    )))
  })

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

  output$excluded_banner <- renderUI({
    res <- generate_result()
    if (nrow(res$excluded_df) == 0) return(NULL)
    tagList(
      div(class = "alert alert-warning",
          strong(sprintf("%d producer(s) excluded from this report - no income was reported in any quarter (Q1-Q4 all zero/blank):",
                         nrow(res$excluded_df)))),
      tags$ul(lapply(res$excluded_df$producer, tags$li))
    )
  })

  output$fallback_table <- renderDT({
    datatable(generate_result()$fallback_df, filter = "top", rownames = FALSE,
              options = list(pageLength = 10, scrollX = TRUE))
  }, server = FALSE)

  output$classification_table <- renderDT({
    datatable(generate_result()$classification_df, filter = "top", rownames = FALSE,
              options = list(pageLength = 10, scrollX = TRUE))
  }, server = FALSE)

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

  ## ---- Render Results outputs while hidden ----
  # (Must come after every output above is defined - outputOptions() errors
  # on an output that doesn't exist yet.)
  #
  # Results outputs render while their panel is still hidden, in the same
  # flush as the generation, instead of waiting for the panel to appear and
  # then asking the server for them. The tables are client-side
  # (server = FALSE): sent once, then paging/sorting/filtering run in the
  # browser with no round trip to R.
  #
  # The download buttons are included too: Shiny renders them disabled until
  # the server sends their URL, which it otherwise only does after the hidden
  # Results panel becomes visible - leaving them greyed out for a while.
  # Their URL doesn't depend on the results, so it is sent at startup.
  for (id in c("validation_banner", "summary_counts", "excluded_banner",
               "fallback_table", "classification_table",
               "download_xml", "download_classification", "download_fallback")) {
    outputOptions(output, id, suspendWhenHidden = FALSE)
  }
}

shinyApp(ui, server)
