# ============================================================================
# Production launcher for the DPI XML Shiny app (app.R)
# ============================================================================
# Location-independent: finds its own folder, so it works unchanged wherever
# the project is cloned, on any machine, whether started by NSSM, a .bat file,
# Task Scheduler or by hand. See DEPLOYMENT.md.
#
#   Rscript run_app.R          # port from APP_PORT, else 3845
#   Rscript run_app.R 3850     # explicit port (overrides APP_PORT)
#
# Listens on all network interfaces (0.0.0.0), so other machines on the LAN
# can open http://<server-name>:<port>/.
# Logs (appended, so crash history survives restarts): logs/app.log
# ============================================================================

# ---- 1. Find this project's folder ------------------------------------------
# Rscript passes the script path as --file=...; fall back to the working
# directory when the file is source()d from an interactive session.
app_dir <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) == 1) {
    dirname(normalizePath(sub("^--file=", "", file_arg), winslash = "/"))
  } else {
    normalizePath(getwd(), winslash = "/")
  }
})
setwd(app_dir)

# ---- 2. Logging ---------------------------------------------------------------
dir.create("logs", showWarnings = FALSE)
log_con <- file(file.path("logs", "app.log"), open = "at")
sink(log_con, type = "output", split = TRUE)   # split: still visible in a console
sink(log_con, type = "message")
log_line <- function(...) {
  cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), ..., "\n", sep = "")
}

log_line("---- starting DPI XML app from ", app_dir, " ----")

exit_code <- tryCatch({

  # ---- 3. Activate the project's renv library -------------------------------
  # .Rprofile (which activates renv) only runs when R *starts* in this folder.
  # If R was started elsewhere, activate it here - otherwise the app would
  # silently run on the global library with different package versions.
  if (!"renv" %in% loadedNamespaces()) source("renv/activate.R")

  this_r <- paste(R.version$major, R.version$minor, sep = ".")
  lock_r <- jsonlite::read_json("renv.lock")$R$Version
  log_line("R ", this_r, " (renv.lock: R ", lock_r, "); library: ", .libPaths()[1])
  if (!identical(sub("\\.[0-9]+$", "", this_r), sub("\\.[0-9]+$", "", lock_r))) {
    log_line("WARNING: R ", this_r, " does not match renv.lock (R ", lock_r, "). ",
             "Point NSSM at R ", lock_r, "'s Rscript.exe.")
  }

  # ---- 4. Port + the URLs users can open ------------------------------------
  cli_args <- commandArgs(trailingOnly = TRUE)
  port <- as.integer(if (length(cli_args) >= 1) cli_args[1] else Sys.getenv("APP_PORT", "3845"))
  if (is.na(port)) stop("Port must be a number (got '", cli_args[1], "').")

  # Informational only - a failure here must never stop the app from starting.
  ips <- tryCatch({
    ipv4_lines <- grep("IPv4", system("ipconfig", intern = TRUE), value = TRUE)
    regmatches(ipv4_lines, regexpr("([0-9]{1,3}\\.){3}[0-9]{1,3}", ipv4_lines))
  }, error = function(e) character())
  log_line("App URL(s): ",
           paste0("http://", c(Sys.info()[["nodename"]], ips), ":", port, "/", collapse = "  "))

  # ---- 5. Run - blocks until the service is stopped --------------------------
  shiny::runApp(app_dir, host = "0.0.0.0", port = port, launch.browser = FALSE)
  0L

}, error = function(e) {
  log_line("ERROR: ", conditionMessage(e))
  1L
})

log_line("app stopped (exit code ", exit_code, ")")
sink(type = "message")
sink(type = "output")
close(log_con)

# Non-zero exit on failure, so NSSM sees the crash and restarts the service.
quit(save = "no", status = exit_code)
