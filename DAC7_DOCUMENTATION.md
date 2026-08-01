# DAC7 / OECD DPI Reporting Tool — Documentation

## 1. Assumptions & Business Rules ("If This, Then That")

This section documents every rule the tool applies to handle missing, ambiguous, or
inconsistently-formatted data in the source spreadsheet, and every requirement imposed by the
Cyprus tax portal (Ariadni) that isn't obvious from the raw data alone.

### A. Seller Classification — Company vs. Individual
- **If** the Company Registration Number matches "HE" or "ΗΕ" (Latin or Greek letters, any
  mix of the two) followed by digits (e.g. `HE307173`, `ΗΕ 425833`) → classify as an **Entity
  (Company)**.
- **Else** (including "ΕΕ"/"ΑΕ" prefixes, or a blank registration number) → classify as an
  **Individual**.
- *Why:* confirmed as an explicit decision — only HE/ΗΕ registration numbers count as
  registered companies for this report; everything else is reported as a person.

### B. Tax Identification Number (TIN)
**For companies:**
- **If** a Tax Number is present → use it as the TIN.
- **Else** → mark the TIN as "unknown".

**For individuals:**
- **If** a Tax Number is present → use it as the TIN.
- **Else if** the ID column has a value → use that ID number as the TIN instead.
- **Else** → mark the TIN as "unknown" **and** attach a placeholder Birthplace (rule D below),
  since the tax portal requires one whenever the TIN is unknown.

### C. Company Registration Number
- **If** present → included in the report as the company's identification number (labelled as
  a Business Registration Number).
- **If** missing → omitted (this field only applies to companies).

### D. Birthplace (individuals only)
- **If** the TIN is "unknown" → include a Birthplace with City = "Unknown" and Country = the
  individual's own tax-residence country, as a placeholder (we don't hold real
  birth-city/country data for anyone).
- **Else** (TIN is known) → no Birthplace is included — the portal only requires it when the
  TIN is unknown.

### E. Date of Birth
- **If** the spreadsheet holds a proper date → use it directly.
- **If** the spreadsheet holds an Excel "serial number" stored as text (e.g. `"26539"`) →
  convert it to a real calendar date automatically.
- **If** missing, blank, or `"N/A"` → use a placeholder date of **1900-01-01**.

### F. Address
- **If** the address is missing, blank, or `"N/A"` → use **"Address unknown"** as a
  placeholder.

### G. Country of Tax Residence
- **If** the country name in the spreadsheet maps to a valid country code → use that code.
- **Else** → default to Cyprus (CY) and log a warning so it can be reviewed.
- **If** an individual's residence country is anything other than Cyprus → **also** list
  Cyprus as an additional residence country. *Why:* the tool only reports service income (not
  property income), and the portal requires Cyprus to appear as a residence country in that
  case, regardless of where the individual actually lives.

### H. Quarterly Financial Data (Income / Fees / Transaction Count)
- **If** a quarterly amount is missing, blank, or shown as `"-"` → treat it as **0**.
- **If** a producer's total annual income (sum of all 4 quarters) is zero or less → the
  producer is **excluded** from the report entirely (nothing to report).
- Tax withheld is always reported as **0** for all 4 quarters, since this isn't tracked in the
  source spreadsheet — the report format requires the field to be present regardless.

### I. Reference IDs (internal document numbers)
- Every record's reference ID always starts with **Cyprus's country code and the reporting
  year**, regardless of where the seller is tax-resident. *Why:* a portal requirement — the
  reference ID identifies the *sender* (Cyprus), not the seller.
- Reference IDs are freshly generated every time the tool runs, so re-running always produces
  new, valid IDs.

### J. Submission Type
- Every submission — including a resubmission after a rejection — is marked as a **new**
  submission, not a "correction". *Why:* a rejected file is never accepted by the tax
  authority in the first place, so there is nothing on file to "correct" — it's a fresh
  attempt.

### K. Platform Operator Details
- The reporting company's own details (name, TIN, VAT, address) are **fixed configuration
  values** typed directly into the tool — they are not read from the spreadsheet. These must
  be checked/updated before every submission if anything changes.

---

## 2. Summary of Changes Made

**Data format update**
1. Updated the tool to read the new quarterly breakdown (Q1–Q4 income/fees/transactions)
   instead of the old three annual-total columns.

**Bug fixes**
2. Fixed a bug that could crash the tool on certain birth-date formats.
3. Fixed a character-encoding bug that caused some legitimate registered companies (with
   Greek-lettered "ΗΕ" registration numbers) to be incorrectly reported as individuals.
4. Added a fallback: individuals missing a tax number now use their ID number instead, where
   available.

**New features**
5. Added a CSV export listing every producer and whether they were classified as a company or
   an individual, for quick manual review before submission.

**Fixes for the Ariadni portal rejection**
6. Corrected the internal reference ID format so every record starts with the correct sending
   country code (see rule I above) — some records for sellers outside Cyprus were previously
   malformed.
7. Added the required "place of birth" placeholder for individuals with no tax number on file
   (see rule D above).
8. Added Cyprus as an additional residence country for the small number of sellers tax-resident
   abroad, as required by the portal (see rule G above).
