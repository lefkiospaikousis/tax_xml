# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Single-script R project that generates an **OECD DPI (Digital Platform Information) XML** file for reporting vendor/seller ("producer") data to the **Cyprus Tax Department** (DAC7 reporting). The entire program is [xml.R](xml.R) — read it top-to-bottom, there is no package structure. Input is an Excel file of producers; output is a schema-valid `dpi_report_<YYYYMMDD>.xml`.

## Running

The project uses `renv` (R 4.3.3). `.Rprofile` calls `source("renv/activate.R")`, so any R session in this directory activates the project library automatically.

```r
renv::restore()   # first-time setup: install pinned deps from renv.lock
source("xml.R")   # run end-to-end: reads Excel, builds XML, writes + validates
```

There are no unit tests, no build step, and no linter configured. "Testing" = running `xml.R` and confirming `xml_validate(doc, xsd)` at the end returns `TRUE`.

## Data flow (xml.R, in execution order)

1. **Load + clean** — reads `data/DAC FINAL 2025.xlsx` (path built from `path_main`/`path_data`), renames the verbose Excel headers to snake_case columns, and parses the 12 per-quarter columns (`Q1_INCOME`…`Q4_FEES`) via `parse_amount()` (handles mixed numeric/character columns, `"-"` placeholders, blanks). `DATE OF BIRTH` is parsed via `parse_dob()`, which must handle three possible source shapes: a native `Date`/`POSIXct`, an Excel serial number stored as text (e.g. `"26539"`), or an ISO date string — `readxl` returns whichever depending on column contents, and a naive `as.Date()` on the raw value **will hard-crash** on the serial-number case.
2. **Filter** — keeps rows where `income_q1+…+income_q4 > 0`.
3. **Config blocks** — `platform_operator` and `reporting_config` are edited-in-place literals near the top. `reporting_config$reporting_year` is a **placeholder you must set per run** — it drives both `DocRefId` and `MessageRefId` (kept in sync deliberately; previously `MessageRefId` used `Sys.Date()`'s year, causing a mismatch with `DocRefId`'s reporting year). `reporting_config$message_type_indic` selects DPI401 (new) / DPI402 (correction) / DPI403 (nil) — see the notes at the bottom of `xml.R` for the OECD1/2/3 `DocTypeIndic` correction semantics.
4. **XML build** — `create_dpi_xml()` builds the tree with `xml2`: `MessageSpec` header, then one `ReportableSeller` per producer under `DPIBody`.
5. **Write + validate** — writes to `exports/dpi_report_<date>.xml`, then re-reads and validates against `data/xsd_validation/DPIXML_v1.0.xsd`, printing `XSD validation: PASSED`/`FAILED` (with `attr(result, "errors")` on failure).

## Key domain logic (edit these carefully — they encode tax-reporting rules)

- **Entity vs. individual** — `is_entity()` treats a producer as a company **only** if `company_reg` matches an `HE`/`ΗΕ` registration prefix (any Latin/Greek letter mix — see below), in ANY of e.g. `HE`, `ΗΕ`, `HΕ`, `ΗE`, followed by digits. Everything else — including `ΕΕ`/`ΑΕ` (Greek partnership/PLC prefixes present in real data) and blanks — is an individual. This was an explicit product decision (not all registered-entity prefixes count, only HE/ΗΕ). Entities → `add_entity_seller()` (`EntSellerID`, `IN`=BRN); everyone else → `add_individual_seller()` (name parsed by `parse_name_parts()`, requires `BirthInfo`).
  - **Encoding gotcha:** the regex is built from `intToUtf8(0x0397)`/`intToUtf8(0x0395)` rather than literal Greek characters in the source. On this environment R's native codepage is Windows-1252 (not UTF-8) — a literal Greek `Η`/`Ε` typed directly into the `.R` file gets silently corrupted when the file is parsed outside an editor/IDE that forces UTF-8 source encoding, and the regex then only matches mixed Latin/Greek variants (missing most real pure-Greek `ΗΕ` values). Do not reintroduce literal non-ASCII characters into regex patterns in this file — always build them via `intToUtf8()`.
- **TIN fallback** — `add_individual_seller()` uses `tax_number` for the TIN if present, else falls back to the `ID` Excel column (`id_number`, `issuedBy=CY`), else emits `TIN unknown="true"`. Entities never use `ID`/`id_number` (the DPI schema's `EntSellerID` has no such field for it — entities only get `IN`, from `company_reg`).
- **Country codes** — `map_country_name_to_code()` uses the `countrycode` package to map a country name to ISO2, **defaulting to `"CY"`** (with a `message()` naming the unmatched input) on failure. IBAN-prefix inference was deliberately abandoned (see commented note — wrong for Revolut/Lithuania cases).
- **Quarterly amounts** — `add_relevant_activities()` (via the `add_quarterly()` helper) emits the **real** per-quarter income/fees/transaction counts from the source columns; `Taxes` stays all-zero (not present in source data, but the XSD block is mandatory). All monetary quarters require `currCode="EUR"` and must be whole integers (`xsd:integer`) — values are rounded.
- **Missing values** — missing address → `AddressFree` = "Address unknown"; missing DOB → `placeholder_dob` (`1900-01-01`).
- **IDs** — `DocRefId` / `MessageRefId` are generated per-run with `uuid::UUIDgenerate()`, so they differ every run (correct for new submissions).

## XML construction conventions

- Built imperatively with `xml2::xml_add_child` / `xml_set_attr`; elements are namespace-prefixed `dpi:` (`urn:oecd:ties:dpi:v1`) and `stf:` (`urn:oecd:ties:dpistf:v1`). Preserve these prefixes and element ordering — the XSD is order-sensitive.
- `DAC7_Sample_file.xml` is a reference example of the target format (confirms per-quarter blocks are integers with mandatory `currCode`, and that `IndSellerID`/`EntSellerID` have no shared identifier element); `dd9c663f-en.pdf` is the OECD DPI schema user guide.

## Notes

- Paths are hardcoded to the author's machine (`c:/Users/pcuser/OneDrive/IMPROVAST/ACS/tax_xml`, via `path_main`); update if the repo moves.
- `platform_operator` currently holds **sample/placeholder** TIN/VAT/address values — verify against real operator details before any real submission.
- The Excel input schema has changed over time (previously three `TOTAL ... PER YEAR` columns, now 12 per-quarter columns plus `ID`) — if a new input file arrives with yet another column layout, re-check `parse_amount()`/`parse_dob()` against the actual column types with `readxl::read_excel()` + `sapply(x, class)` before assuming the existing parsing logic still applies; column types can vary between "numeric", "character", and "logical" (all-`NA` columns) depending on what Excel guesses per column.
