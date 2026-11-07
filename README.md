# DAC7 / OECD DPI XML Generator

Builds the **DAC7 report** that a digital platform operator files with the
**Cyprus Tax Department**: an XML file in the OECD **DPI (Digital Platform
Information)** format, listing every seller ("producer") who earned income
through the platform during the year.

You upload the producers spreadsheet, review the operator details, and press
one button. The tool then:

1. classifies each seller as a **company** or an **individual**,
2. fills gaps in the source data (missing TIN, date of birth, address...)
   using documented rules and **reports every gap it filled**,
3. builds the XML with the real per-quarter income, fees and transaction
   counts,
4. **validates it against the official OECD DPI schema (XSD)** before you
   download it.

---

## Two ways to run it

| | **Shiny app** (`app.R`) | **Script** (`xml.R`) |
|---|---|---|
| For | day-to-day use, non-R users | quick runs from R |
| Input | uploaded through the browser | `data/DAC FINAL 2025.xlsx` (path set in the script) |
| Config | form in the sidebar | edit the `platform_operator` / `reporting_config` lists in the script |
| Output | downloaded from the browser, with fallback report + classification CSVs | `exports/dpi_report_<YYYYMMDD>.xml` |

Both use the same rules from `dpi_functions.R`, so they always produce the
same result.

---

## Quick start

Requires **R 4.3.3** (the version in `renv.lock`).

```r
# one-time: install the exact package versions
renv::restore()

# run the app locally
shiny::runApp()

# ...or run the script
source("xml.R")
```

Opening the project folder in R/RStudio activates `renv` automatically (via
`.Rprofile`).

For the production server (Windows service via NSSM), see
**[DEPLOYMENT.md](DEPLOYMENT.md)**. In short: `Rscript run_app.R`, which
serves the app on port 3845 to the local network.

---

## Using the app

1. **Upload** the producers Excel file (`.xlsx`). The app checks that every
   required column is present.
2. **Review the configuration** in the sidebar: platform operator TIN, VAT,
   name and address, reporting year, message type, and the placeholder date
   of birth for sellers without one.
   - Country is always **Cyprus**. District is taken from City.
   - The reporting period is always the full calendar year (1 Jan to 31 Dec)
     of the reporting year.
3. **Generate DPI XML.** Progress shows at the top of the screen. You get
   a popup when it's done.
4. **Check the results:**
   - **XSD validation**: must say **PASSED** before you submit the file.
   - **Excluded producers**: sellers with no income in any quarter. These
     are left out of the report.
   - **Missing data / fallback report**: every place the source data was
     missing or ambiguous, and what the tool used instead.
   - **Seller classification**: who was reported as a company and who as a
     person.
5. **Download** the XML (and, if you want, both reports as CSV) from the
   green bar at the top of the results.

---

## Input file

One row per producer. The column names must match exactly:

| Column | Used for |
|---|---|
| `PRODUCER` | seller name (individuals are split into first/last name) |
| `COMPANY REGISTRATION NUMBER` | company vs. individual (see below); the company's registration ID |
| `TAX NUMBER` | the seller's TIN |
| `ID` | TIN fallback for individuals with no tax number |
| `DATE OF BIRTH` | individuals' birth date (Excel date, Excel serial number or ISO text are all accepted) |
| `ADDRESS` | seller address |
| `COUNTRY TAX RESIDENCE` | country of residence (name → ISO code) |
| `IBAN` | the seller's financial identifier (spaces removed) |
| `EMAIL ADDRESS`, `BANK` | must be present, but are not written to the XML |
| `Q1_INCOME` ... `Q4_INCOME` | income per quarter |
| `Q1_FEES` ... `Q4_FEES` | platform fees per quarter |
| `Q1_TRANSACTIONS` ... `Q4_TRANSACTIONS` | number of transactions per quarter |

Amount columns can contain numbers, text numbers, `-` or blanks. Blanks and
`-` count as 0. Amounts are rounded to whole euros, as the schema requires.

Producers files contain personal data and **must never be committed** to
git. Check `git status` before committing anything in `data/`.

---

## Key rules (summary)

The full list, with the reasoning behind each rule, is in
**[DAC7_DOCUMENTATION.md](DAC7_DOCUMENTATION.md)**.

- **Company vs. individual**: a seller is a **company** only if its
  registration number is an `HE` / `ΗΕ` number (Latin or Greek letters,
  e.g. `HE307173`, `ΗΕ 425833`). Everything else, including `ΕΕ`/`ΑΕ`
  prefixes and blanks, is reported as an **individual**.
- **TIN**: the tax number is used if present. For individuals the `ID` column
  is used next. Otherwise the TIN is marked *unknown*.
- **Missing date of birth** → the placeholder date (default `1900-01-01`).
- **Missing address** → `Address unknown`.
- **Unrecognised country** → `CY`.
- **Reporting period**: 31 Dec of the reporting year. Message reference IDs
  are new on every run (correct for a new submission, `DPI401`).

Every fallback applied is listed in the app's fallback report, so nothing
is filled in silently.

---

## Project layout

```
app.R               Shiny app (UI + server)
dpi_functions.R     all business rules and XML building (shared by app and script)
xml.R               script version: reads a file from data/, writes to exports/
run_app.R           production launcher (used by the NSSM service)

data/
  xsd_validation/   official OECD DPI schemas the output is validated against
  DAC7_Sample_file.xml   reference example of a valid DPI file (dummy data)
  dd9c663f-en.pdf        OECD DPI XML schema user guide
  *.xlsx                 producers input files (personal data - keep out of git)

DAC7_DOCUMENTATION.md   business rules and their reasoning
DEPLOYMENT.md           production deployment (NSSM service, updates, troubleshooting)
CLAUDE.md               notes for AI-assisted development
renv.lock               exact package versions
```

---

## Before a real submission

- Check the **platform operator details** (TIN, VAT, address). The defaults
  in `app.R` / `xml.R` started as sample values.
- Set the correct **reporting year**.
- Confirm **XSD validation: PASSED**.
- Read the **fallback report**. Each line is data the tax portal will see
  as a placeholder, such as an unknown TIN or a `1900-01-01` birth date.
  Fixing the source spreadsheet and regenerating is better than submitting
  placeholders.
- For corrections or nil returns (`DPI402` / `DPI403`), see the notes at the
  bottom of `xml.R`.
